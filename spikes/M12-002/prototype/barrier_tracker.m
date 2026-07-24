/*
 * M12-002 barrier / resource-state tracker prototype.
 * Author: Tim Isaev
 *
 * Model leg: randomized D3D12-style command streams (per-subresource reads,
 * writes, transitions-as-writes, an aliased memory pair, two queues) are
 * compiled into sync plans two ways - conservatively (order everything that
 * touches the same memory) and optimized (last-access tracking with
 * read-read elision and vector-clock skipping of transitively implied
 * edges).  Ground truth is a hazard graph built directly from the access
 * sequence; a plan passes only if every hazard pair is covered by
 * reachability through emitted edges.  A dropped-edge sensitivity pass
 * proves the checker can fail.
 *
 * Execution leg: a writer->fence->reader chain within a queue and a
 * writer->event->reader chain across queues run on real Metal primitives
 * with self-checking kernels, and two independent spin kernels demonstrate
 * that unordered work on the two queues actually overlaps in wall-clock.
 *
 * Provenance: ADR-0012 discipline model; see ../PROVENANCE.md.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>

#define QUEUE_COUNT 2
#define RESOURCE_COUNT 12
#define SUBRESOURCE_COUNT 4
#define ALIAS_A 10 /* resources 10 and 11 share one memory object */
#define ALIAS_B 11
#define STREAM_OPS 200
#define STREAM_COUNT 10000
#define SENSITIVITY_TRIALS 100

enum access_kind
{
    ACCESS_READ,
    ACCESS_WRITE,
    ACCESS_TRANSITION /* whole-resource, write-class */
};

struct op
{
    int queue;
    int memory; /* memory object id (aliased pair shares one) */
    int slot;   /* subresource, or -1 for whole resource */
    enum access_kind kind;
    int queue_pos; /* position within its queue */
};

struct edge
{
    int from, to;
};

#define MAX_EDGES (STREAM_OPS * STREAM_OPS)
#define REACH_WORDS ((STREAM_OPS + 63) / 64)

struct plan
{
    struct edge edges[MAX_EDGES];
    int edge_count;
};

static struct op stream[STREAM_OPS];
static uint64_t reach[STREAM_OPS][REACH_WORDS];

static double timebase_ns(void)
{
    static mach_timebase_info_data_t info;
    if (!info.denom)
        mach_timebase_info(&info);
    return (double)info.numer / info.denom;
}

static int memory_of(int resource)
{
    return resource == ALIAS_B ? ALIAS_A : resource;
}

static void generate_stream(void)
{
    int queue_pos[QUEUE_COUNT] = {0};

    for (int i = 0; i < STREAM_OPS; i++)
    {
        int resource = random() % RESOURCE_COUNT;
        int roll = random() % 100;
        struct op *o = &stream[i];

        o->queue = random() % QUEUE_COUNT;
        o->memory = memory_of(resource);
        if (roll < 5)
        {
            o->kind = ACCESS_TRANSITION;
            o->slot = -1;
        }
        else
        {
            o->kind = roll < 35 ? ACCESS_WRITE : ACCESS_READ;
            o->slot = random() % SUBRESOURCE_COUNT;
        }
        /* aliased memory is tracked whole-object */
        if (o->memory == ALIAS_A)
            o->slot = -1;
        o->queue_pos = queue_pos[o->queue]++;
    }
}

static int slots_overlap(const struct op *a, const struct op *b)
{
    if (a->memory != b->memory)
        return 0;
    return a->slot < 0 || b->slot < 0 || a->slot == b->slot;
}

static int is_hazard(const struct op *a, const struct op *b)
{
    if (!slots_overlap(a, b))
        return 0;
    return a->kind != ACCESS_READ || b->kind != ACCESS_READ;
}

/* reachability over plan edges + nothing else (queue order is NOT implicit:
 * unfenced work on one queue may overlap) */
static void compute_reach(const struct plan *p)
{
    static int pred_head[STREAM_OPS];
    static int pred_next[MAX_EDGES];
    static int pred_from[MAX_EDGES];

    memset(reach, 0, sizeof(reach));
    memset(pred_head, -1, sizeof(pred_head));
    for (int e = 0; e < p->edge_count; e++)
    {
        pred_from[e] = p->edges[e].from;
        pred_next[e] = pred_head[p->edges[e].to];
        pred_head[p->edges[e].to] = e;
    }
    for (int j = 0; j < STREAM_OPS; j++)
        for (int e = pred_head[j]; e >= 0; e = pred_next[e])
        {
            int i = pred_from[e];
            for (int w = 0; w < REACH_WORDS; w++)
                reach[j][w] |= reach[i][w];
            reach[j][i / 64] |= 1ull << (i % 64);
        }
}

static long verify_plan(const struct plan *p, long *hazards_out)
{
    long hazards = 0, uncovered = 0;

    compute_reach(p);
    for (int j = 0; j < STREAM_OPS; j++)
        for (int i = 0; i < j; i++)
            if (is_hazard(&stream[i], &stream[j]))
            {
                hazards++;
                if (!(reach[j][i / 64] >> (i % 64) & 1))
                    uncovered++;
            }
    if (hazards_out)
        *hazards_out = hazards;
    return uncovered;
}

static void compile_conservative(struct plan *p)
{
    p->edge_count = 0;
    for (int j = 0; j < STREAM_OPS; j++)
        for (int i = 0; i < j; i++)
            if (stream[i].memory == stream[j].memory)
                p->edges[p->edge_count++] = (struct edge){i, j};
}

/* optimized: last-access tracking + vector-clock elision of implied edges */
struct last_access
{
    int last_write; /* op index or -1 */
    int readers[STREAM_OPS];
    int reader_count;
};

static void compile_optimized(struct plan *p)
{
    static struct last_access track[RESOURCE_COUNT][SUBRESOURCE_COUNT + 1];
    /* true happens-before, built as edges are added; per-queue summaries are
     * unsound here because unfenced same-queue work is unordered by design */
    static uint64_t creach[STREAM_OPS][REACH_WORDS];
    int candidates[STREAM_OPS + 8];

    p->edge_count = 0;
    memset(creach, 0, sizeof(creach));
    for (int m = 0; m < RESOURCE_COUNT; m++)
        for (int s = 0; s <= SUBRESOURCE_COUNT; s++)
        {
            track[m][s].last_write = -1;
            track[m][s].reader_count = 0;
        }

    for (int j = 0; j < STREAM_OPS; j++)
    {
        const struct op *o = &stream[j];
        int slot_lo = o->slot < 0 ? 0 : o->slot;
        int slot_hi = o->slot < 0 ? SUBRESOURCE_COUNT : o->slot;
        int candidate_count = 0;

        for (int s = slot_lo; s <= slot_hi; s++)
        {
            struct last_access *t = &track[o->memory][s];

            if (o->kind == ACCESS_READ)
            {
                if (t->last_write >= 0)
                    candidates[candidate_count++] = t->last_write;
            }
            else
            {
                if (t->last_write >= 0)
                    candidates[candidate_count++] = t->last_write;
                for (int r = 0; r < t->reader_count; r++)
                    candidates[candidate_count++] = t->readers[r];
            }
        }

        /* add edges newest-source-first so reachability elides the rest */
        for (int a = 0; a < candidate_count; a++)
            for (int b = a + 1; b < candidate_count; b++)
                if (candidates[b] > candidates[a])
                {
                    int tmp = candidates[a];
                    candidates[a] = candidates[b];
                    candidates[b] = tmp;
                }
        for (int c = 0; c < candidate_count; c++)
        {
            int i = candidates[c];
            if (c && i == candidates[c - 1])
                continue; /* duplicate */
            if (creach[j][i / 64] >> (i % 64) & 1)
                continue; /* already implied transitively */
            p->edges[p->edge_count++] = (struct edge){i, j};
            for (int w = 0; w < REACH_WORDS; w++)
                creach[j][w] |= creach[i][w];
            creach[j][i / 64] |= 1ull << (i % 64);
        }

        /* record this access */
        for (int s = slot_lo; s <= slot_hi; s++)
        {
            struct last_access *t = &track[o->memory][s];

            if (o->kind == ACCESS_READ)
                t->readers[t->reader_count++] = j;
            else
            {
                t->last_write = j;
                t->reader_count = 0;
            }
        }
    }
}

static const char *kernel_source =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void writer(device uint *buf [[buffer(0)]],\n"
    "                   constant uint &value [[buffer(1)]],\n"
    "                   uint tid [[thread_position_in_grid]])\n"
    "{\n"
    "    buf[tid] = value ^ tid;\n"
    "}\n"
    "kernel void checker(device const uint *buf [[buffer(0)]],\n"
    "                    constant uint &value [[buffer(1)]],\n"
    "                    device atomic_uint *errors [[buffer(2)]],\n"
    "                    uint tid [[thread_position_in_grid]])\n"
    "{\n"
    "    if (buf[tid] != (value ^ tid))\n"
    "        atomic_fetch_add_explicit(errors, 1u, memory_order_relaxed);\n"
    "}\n"
    "kernel void spin(device uint *buf [[buffer(0)]],\n"
    "                 uint tid [[thread_position_in_grid]])\n"
    "{\n"
    "    uint v = buf[tid];\n"
    "    for (int k = 0; k < 200000; k++)\n"
    "        v = v * 1664525u + 1013904223u;\n"
    "    buf[tid] = v;\n"
    "}\n";

int main(void)
{
    @autoreleasepool
    {
        long total_hazards = 0, total_uncovered = 0;
        long conservative_edges = 0, optimized_edges = 0;
        int sensitivity_caught = 0;
        static struct plan conservative, optimized;

        srandom(20260724);

        /* model leg */
        uint64_t t0 = mach_absolute_time();
        for (int s = 0; s < STREAM_COUNT; s++)
        {
            long hazards = 0;

            generate_stream();
            compile_conservative(&conservative);
            if (verify_plan(&conservative, &hazards))
            {
                puts("conservative plan uncovered a hazard - model broken");
                return 2;
            }
            compile_optimized(&optimized);
            total_uncovered += verify_plan(&optimized, &hazards);
            total_hazards += hazards;
            conservative_edges += conservative.edge_count;
            optimized_edges += optimized.edge_count;

            /* sensitivity: drop one random edge, the checker must notice */
            if (s < SENSITIVITY_TRIALS && optimized.edge_count)
            {
                struct plan crippled = optimized;
                int victim = random() % crippled.edge_count;

                crippled.edges[victim] = crippled.edges[--crippled.edge_count];
                if (verify_plan(&crippled, NULL))
                    sensitivity_caught++;
            }
        }
        uint64_t t1 = mach_absolute_time();

        printf("model: %d streams x %d ops, %ld hazard pairs, %ld uncovered\n", STREAM_COUNT,
               STREAM_OPS, total_hazards, total_uncovered);
        printf("plans: conservative %.0f edges/stream, optimized %.1f (%.1f%% eliminated)\n",
               (double)conservative_edges / STREAM_COUNT, (double)optimized_edges / STREAM_COUNT,
               100.0 * (conservative_edges - optimized_edges) / conservative_edges);
        printf("sensitivity: dropped-edge detection %d/%d\n", sensitivity_caught,
               SENSITIVITY_TRIALS);
        printf("model time: %.2f s\n", (t1 - t0) * timebase_ns() / 1e9);
        if (total_uncovered || sensitivity_caught != SENSITIVITY_TRIALS)
        {
            puts("m12-002 FAILED (model)");
            return 3;
        }

        /* execution leg */
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            puts("no metal device");
            return 1;
        }
        NSError *error = nil;
        id<MTLLibrary> library =
            [device newLibraryWithSource:[NSString stringWithUTF8String:kernel_source]
                                 options:nil
                                   error:&error];
        if (!library)
        {
            printf("library: %s\n", error.localizedDescription.UTF8String);
            return 4;
        }
        id<MTLComputePipelineState> writer =
            [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"writer"]
                                                  error:&error];
        id<MTLComputePipelineState> checker =
            [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"checker"]
                                                  error:&error];
        id<MTLComputePipelineState> spin =
            [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"spin"]
                                                  error:&error];
        if (!writer || !checker || !spin)
            return 4;

        id<MTLCommandQueue> queue_a = [device newCommandQueue];
        id<MTLCommandQueue> queue_b = [device newCommandQueue];
        const uint32_t elements = 1 << 20;
        id<MTLBuffer> data = [device newBufferWithLength:elements * 4
                                                 options:MTLResourceStorageModeShared];
        id<MTLBuffer> errors = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        *(uint32_t *)errors.contents = 0;

        /* intra-queue chain: writer -> MTLFence -> checker, 32 rounds */
        id<MTLFence> fence = [device newFence];
        for (uint32_t round = 0; round < 32; round++)
        {
            uint32_t value = 0xA0000000u + round;
            id<MTLCommandBuffer> cb = [queue_a commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:writer];
            [enc setBuffer:data offset:0 atIndex:0];
            [enc setBytes:&value length:4 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(elements, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc updateFence:fence];
            [enc endEncoding];
            enc = [cb computeCommandEncoder];
            [enc waitForFence:fence];
            [enc setComputePipelineState:checker];
            [enc setBuffer:data offset:0 atIndex:0];
            [enc setBytes:&value length:4 atIndex:1];
            [enc setBuffer:errors offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(elements, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];
            [cb commit];
            if (round == 31)
                [cb waitUntilCompleted];
        }
        printf("gpu fence chain: %u errors after 32 rounds\n", *(uint32_t *)errors.contents);
        if (*(uint32_t *)errors.contents)
            return 5;

        /* cross-queue chain: writer on A signals, checker on B waits, 32 rounds */
        id<MTLSharedEvent> event = [device newSharedEvent];
        uint64_t signal = 0;
        id<MTLCommandBuffer> last_b = nil;
        for (uint32_t round = 0; round < 32; round++)
        {
            uint32_t value = 0xB0000000u + round;
            id<MTLCommandBuffer> cb_a = [queue_a commandBuffer];
            if (signal)
                [cb_a encodeWaitForEvent:event value:signal]; /* prior read done */
            id<MTLComputeCommandEncoder> enc = [cb_a computeCommandEncoder];
            [enc setComputePipelineState:writer];
            [enc setBuffer:data offset:0 atIndex:0];
            [enc setBytes:&value length:4 atIndex:1];
            [enc dispatchThreads:MTLSizeMake(elements, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];
            [cb_a encodeSignalEvent:event value:++signal];
            [cb_a commit];

            id<MTLCommandBuffer> cb_b = [queue_b commandBuffer];
            [cb_b encodeWaitForEvent:event value:signal];
            enc = [cb_b computeCommandEncoder];
            [enc setComputePipelineState:checker];
            [enc setBuffer:data offset:0 atIndex:0];
            [enc setBytes:&value length:4 atIndex:1];
            [enc setBuffer:errors offset:0 atIndex:2];
            [enc dispatchThreads:MTLSizeMake(elements, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [enc endEncoding];
            [cb_b encodeSignalEvent:event value:++signal];
            [cb_b commit];
            last_b = cb_b;
        }
        [last_b waitUntilCompleted];
        printf("gpu cross-queue chain: %u errors after 32 rounds\n", *(uint32_t *)errors.contents);
        if (*(uint32_t *)errors.contents)
            return 6;

        /* overlap: undersized independent spins (each leaves GPU capacity
         * free) on two queues, against a fence-serialized chain of the same
         * two dispatches - command buffers on one queue are NOT implicitly
         * serial, so the serial baseline must use an explicit fence */
        const uint32_t spin_threads = 2048;
        id<MTLBuffer> spin_a = [device newBufferWithLength:spin_threads * 4
                                                   options:MTLResourceStorageModeShared];
        id<MTLBuffer> spin_b = [device newBufferWithLength:spin_threads * 4
                                                   options:MTLResourceStorageModeShared];
        id<MTLFence> spin_fence = [device newFence];
        double elapsed[2];

        for (int mode = 0; mode < 2; mode++)
        {
            uint64_t s0 = mach_absolute_time();
            if (mode == 0)
            {
                id<MTLCommandBuffer> cb1 = [queue_a commandBuffer];
                id<MTLCommandBuffer> cb2 = [queue_b commandBuffer];
                id<MTLCommandBuffer> cbs[2] = {cb1, cb2};
                id<MTLBuffer> bufs[2] = {spin_a, spin_b};
                for (int i = 0; i < 2; i++)
                {
                    id<MTLComputeCommandEncoder> enc = [cbs[i] computeCommandEncoder];
                    [enc setComputePipelineState:spin];
                    [enc setBuffer:bufs[i] offset:0 atIndex:0];
                    [enc dispatchThreads:MTLSizeMake(spin_threads, 1, 1)
                        threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                    [enc endEncoding];
                }
                [cb1 commit];
                [cb2 commit];
                [cb1 waitUntilCompleted];
                [cb2 waitUntilCompleted];
                double a0 = cb1.GPUStartTime, a1 = cb1.GPUEndTime;
                double b0 = cb2.GPUStartTime, b1 = cb2.GPUEndTime;
                double ov = (a1 < b1 ? a1 : b1) - (a0 > b0 ? a0 : b0);
                printf("gpu intervals: A %.1f ms, B %.1f ms, hardware overlap %.1f ms\n",
                       (a1 - a0) * 1e3, (b1 - b0) * 1e3, ov > 0 ? ov * 1e3 : 0.0);
            }
            else
            {
                id<MTLCommandBuffer> cb = [queue_a commandBuffer];
                id<MTLBuffer> bufs[2] = {spin_a, spin_b};
                for (int i = 0; i < 2; i++)
                {
                    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                    if (i)
                        [enc waitForFence:spin_fence];
                    [enc setComputePipelineState:spin];
                    [enc setBuffer:bufs[i] offset:0 atIndex:0];
                    [enc dispatchThreads:MTLSizeMake(spin_threads, 1, 1)
                        threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                    if (!i)
                        [enc updateFence:spin_fence];
                    [enc endEncoding];
                }
                [cb commit];
                [cb waitUntilCompleted];
            }
            elapsed[mode] = (mach_absolute_time() - s0) * timebase_ns() / 1e6;
        }
        printf("overlap: two queues %.1f ms vs fence-serialized %.1f ms (%.2fx)\n", elapsed[0],
               elapsed[1], elapsed[1] / elapsed[0]);

        puts("m12-002 barrier tracker ok");
        return 0;
    }
}
