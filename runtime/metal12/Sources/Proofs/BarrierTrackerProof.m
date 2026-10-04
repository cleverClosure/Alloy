/*
 * M12-002 barrier / resource-state tracker runtime proof.
 * Author: Timur Isaev
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
 * Provenance: ADR-0012 discipline model; see ../../PROVENANCE.md.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "../Models/AM12BarrierTracker.h"

#include <mach/mach_time.h>
#include <stdlib.h>

#define QUEUE_COUNT 2
#define RESOURCE_COUNT 12
#define SUBRESOURCE_COUNT 4
#define ALIAS_A 10 /* resources 10 and 11 share one memory object */
#define ALIAS_B 11
#define STREAM_OPS 200
#define STREAM_COUNT 10000
#define SENSITIVITY_TRIALS 100

#define MAX_EDGES (STREAM_OPS * STREAM_OPS)

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

static int generate_stream(AM12BarrierTracker *tracker)
{
    AM12BarrierTrackerResetAccesses(tracker);

    for (int i = 0; i < STREAM_OPS; i++)
    {
        int resource = random() % RESOURCE_COUNT;
        int roll = random() % 100;
        uint32_t queue = (uint32_t)(random() % QUEUE_COUNT);
        AM12BarrierAccessKind kind;
        int32_t subresource;

        if (roll < 5)
        {
            kind = AM12_BARRIER_ACCESS_TRANSITION;
            subresource = AM12_BARRIER_ALL_SUBRESOURCES;
        }
        else
        {
            kind = roll < 35 ? AM12_BARRIER_ACCESS_WRITE : AM12_BARRIER_ACCESS_READ;
            subresource = (int32_t)(random() % SUBRESOURCE_COUNT);
        }
        /* aliased memory is tracked whole-object */
        uint32_t memory = (uint32_t)memory_of(resource);
        if (memory == ALIAS_A)
            subresource = AM12_BARRIER_ALL_SUBRESOURCES;
        if (!AM12BarrierTrackerRecordAccess(tracker, queue, memory, subresource, kind, NULL))
            return 0;
    }
    return 1;
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

int AM12RunBarrierTrackerProof(void)
{
    @autoreleasepool
    {
        long total_hazards = 0, total_uncovered = 0;
        long conservative_edges = 0, optimized_edges = 0;
        int sensitivity_caught = 0;
        static AM12BarrierEdge conservative_storage[MAX_EDGES];
        static AM12BarrierEdge optimized_storage[MAX_EDGES];
        static AM12BarrierEdge crippled_storage[MAX_EDGES];
        AM12BarrierPlan conservative;
        AM12BarrierPlan optimized;
        AM12BarrierPlan crippled;
        AM12BarrierTrackerDescriptor descriptor = {
            .max_access_count = STREAM_OPS,
            .memory_object_count = RESOURCE_COUNT,
            .subresource_count = SUBRESOURCE_COUNT,
            .queue_count = QUEUE_COUNT,
        };
        AM12BarrierTracker *tracker = AM12BarrierTrackerCreate(&descriptor);

        if (!tracker ||
            !AM12BarrierPlanInitialize(&conservative, conservative_storage, MAX_EDGES) ||
            !AM12BarrierPlanInitialize(&optimized, optimized_storage, MAX_EDGES) ||
            !AM12BarrierPlanInitialize(&crippled, crippled_storage, MAX_EDGES))
        {
            AM12BarrierTrackerDestroy(tracker);
            puts("barrier tracker model initialization failed");
            return 2;
        }

        srandom(20260724);

        /* model leg */
        uint64_t t0 = mach_absolute_time();
        for (int s = 0; s < STREAM_COUNT; s++)
        {
            AM12BarrierVerification verification;

            if (!generate_stream(tracker) ||
                !AM12BarrierTrackerCompileConservative(tracker, &conservative) ||
                !AM12BarrierTrackerVerifyPlan(tracker, &conservative, &verification))
            {
                AM12BarrierTrackerDestroy(tracker);
                puts("barrier tracker model operation failed");
                return 2;
            }
            if (verification.uncovered_hazard_count)
            {
                AM12BarrierTrackerDestroy(tracker);
                puts("conservative plan uncovered a hazard - model broken");
                return 2;
            }
            if (!AM12BarrierTrackerCompileOptimized(tracker, &optimized) ||
                !AM12BarrierTrackerVerifyPlan(tracker, &optimized, &verification))
            {
                AM12BarrierTrackerDestroy(tracker);
                puts("barrier tracker model operation failed");
                return 2;
            }
            total_uncovered += (long)verification.uncovered_hazard_count;
            total_hazards += (long)verification.hazard_count;
            conservative_edges += conservative.edge_count;
            optimized_edges += optimized.edge_count;

            /* sensitivity: drop one random edge, the checker must notice */
            if (s < SENSITIVITY_TRIALS && optimized.edge_count)
            {
                uint32_t victim = (uint32_t)(random() % optimized.edge_count);

                if (!AM12BarrierPlanCopy(&crippled, &optimized) ||
                    !AM12BarrierPlanRemoveEdgeSwapLast(&crippled, victim) ||
                    !AM12BarrierTrackerVerifyPlan(tracker, &crippled, &verification))
                {
                    AM12BarrierTrackerDestroy(tracker);
                    puts("barrier tracker sensitivity operation failed");
                    return 2;
                }
                if (verification.uncovered_hazard_count)
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
            AM12BarrierTrackerDestroy(tracker);
            puts("m12-002 FAILED (model)");
            return 3;
        }
        AM12BarrierTrackerDestroy(tracker);

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
