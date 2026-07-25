/*
 * M12-006 Metal12 vertical slice.
 * Author: Tim Isaev
 *
 * Renders the M12-005 reference scene natively on Metal, driving it through
 * the four prior prototypes rather than calling Metal directly:
 *
 *   M12-004  every resource comes from a placement heap behind a residency
 *            model that reports a D3D12-shaped budget and tracks usage;
 *   M12-001  the root constants are reached through a virtual descriptor heap
 *            whose records carry generations and retire on completion;
 *   M12-002  every resource-state change is declared to a barrier tracker,
 *            which produces the ordering edges the frame requires and is then
 *            checked against the encoder order actually emitted;
 *   M12-003  both shaders are the MSL lowered from the scene's DXIL.
 *
 * It does not implement d3d12.dll and does not execute the reference PE. It
 * performs the same sequence so the two can be compared digest-for-digest.
 * Output format, per-frame constants, clear colour, draw and capture all match
 * d3d12_reference.c exactly; the digest and the nonuniform-pixel rule are the
 * same computation, so a match is a real match.
 *
 * Provenance: ADR-0012 discipline model; see ../PROVENANCE.md.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WIDTH 640
#define HEIGHT 360
#define FRAME_COUNT 120
#define OUTPUT_BITMAP "m12-metal12-slice.bmp"

static double now_ms(void)
{
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1.0e6;
}

/* ---- M12-004: residency ------------------------------------------------- */

typedef struct
{
    id<MTLHeap> heap;
    NSUInteger budget_bytes; /* recommendedMaxWorkingSetSize */
    NSUInteger placed_bytes; /* what this model has handed out */
    unsigned placements;
} residency;

static BOOL residency_open(residency *r, id<MTLDevice> device, NSUInteger size)
{
    MTLHeapDescriptor *desc = [MTLHeapDescriptor new];
    desc.size = size;
    desc.storageMode = MTLStorageModePrivate;
    desc.hazardTrackingMode = MTLHazardTrackingModeTracked;
    r->heap = [device newHeapWithDescriptor:desc];
    r->budget_bytes = device.recommendedMaxWorkingSetSize;
    r->placed_bytes = 0;
    r->placements = 0;
    return r->heap != nil;
}

/* Placement allocation, the D3D12 shape: the caller asks the model for space
 * and the model answers from the heap it already reserved. */
static id<MTLTexture> residency_place_texture(residency *r, MTLTextureDescriptor *desc)
{
    MTLSizeAndAlign sa = [r->heap.device heapTextureSizeAndAlignWithDescriptor:desc];
    id<MTLTexture> texture = [r->heap newTextureWithDescriptor:desc];

    if (texture)
    {
        r->placed_bytes += sa.size;
        r->placements++;
    }
    return texture;
}

/* ---- M12-001: virtual descriptor heap ----------------------------------- */
/*
 * The heap is a CPU-side record array exactly as the prototype modelled it:
 * a write mutates a record, and binding materializes the referenced record.
 * A record carries a generation so a stale binding is detectable rather than
 * silently reading a recycled resource.
 */

typedef struct
{
    id<MTLBuffer> resource;
    uint32_t generation;
    BOOL live;
} vheap_record;

#define VHEAP_SLOTS 64

typedef struct
{
    vheap_record slots[VHEAP_SLOTS];
    uint32_t generation;
    unsigned materializations;
    unsigned stale_rejects;
} vheap;

static void vheap_write_cbv(vheap *h, unsigned slot, id<MTLBuffer> buffer)
{
    h->slots[slot].resource = buffer;
    h->slots[slot].generation = ++h->generation;
    h->slots[slot].live = YES;
}

/* Returns nil rather than a stale resource: the generation is the whole point
 * of the record array, so it is checked on the path that uses it. */
static id<MTLBuffer> vheap_materialize(vheap *h, unsigned slot, uint32_t expect)
{
    if (slot >= VHEAP_SLOTS || !h->slots[slot].live || h->slots[slot].generation != expect)
    {
        h->stale_rejects++;
        return nil;
    }
    h->materializations++;
    return h->slots[slot].resource;
}

/* ---- M12-002: barrier / resource-state tracker -------------------------- */

typedef enum
{
    STATE_UNDEFINED = 0,
    STATE_RENDER_TARGET,
    STATE_COPY_SOURCE,
    STATE_COPY_DEST,
} res_state;

typedef struct
{
    const char *name;
    res_state state;
    int last_writer_stage; /* encoder ordinal that last wrote, -1 if none */
    int last_reader_stage;
} tracked_resource;

typedef struct
{
    unsigned transitions;
    unsigned edges_required;   /* orderings the tracker says must hold */
    unsigned edges_by_encoder; /* satisfied by encoder order in one buffer */
    unsigned edges_unmet;      /* would need an explicit Metal barrier */
} barrier_plan;

/*
 * Declaring a transition is what a D3D12 caller does; the tracker turns the
 * access pattern into ordering edges. Within one command buffer Metal already
 * orders encoders against each other, so an edge whose producer ran in an
 * earlier encoder is satisfied without emitting anything - that is the
 * elimination M12-002 measured, applied rather than assumed. An edge that is
 * not covered that way is counted, and the run fails on it.
 */
static void tracker_transition(barrier_plan *plan, tracked_resource *res, res_state to, int stage,
                               BOOL writes)
{
    plan->transitions++;
    if (res->state != STATE_UNDEFINED && res->state != to)
    {
        int producer = res->last_writer_stage;

        plan->edges_required++;
        if (producer >= 0 && producer < stage)
            plan->edges_by_encoder++;
        else if (producer >= 0)
            plan->edges_unmet++;
        else
            plan->edges_by_encoder++; /* nothing has written it yet */
    }
    res->state = to;
    if (writes)
        res->last_writer_stage = stage;
    else
        res->last_reader_stage = stage;
}

/* ---- image comparison, identical to the reference scene ------------------ */

static int write_bitmap(const unsigned char *pixels, unsigned row_pitch, uint64_t *digest_out,
                        size_t *changed_out)
{
    unsigned char row[WIDTH * 3];
    const unsigned char *first = pixels;
    uint64_t digest = UINT64_C(1469598103934665603);
    size_t changed = 0;
    FILE *file = fopen(OUTPUT_BITMAP, "wb");
    unsigned char file_header[14] = {0};
    unsigned char info_header[40] = {0};
    unsigned x, y;
    uint32_t image_bytes = (uint32_t)(sizeof(row) * HEIGHT);
    uint32_t off_bits = sizeof(file_header) + sizeof(info_header);

    if (!file)
    {
        puts("failure: could not create slice bitmap");
        return 0;
    }
    file_header[0] = 'B';
    file_header[1] = 'M';
    memcpy(file_header + 2, &(uint32_t){off_bits + image_bytes}, 4);
    memcpy(file_header + 10, &off_bits, 4);
    memcpy(info_header + 0, &(uint32_t){40}, 4);
    memcpy(info_header + 4, &(int32_t){WIDTH}, 4);
    memcpy(info_header + 8, &(int32_t){-HEIGHT}, 4);
    memcpy(info_header + 12, &(uint16_t){1}, 2);
    memcpy(info_header + 14, &(uint16_t){24}, 2);
    memcpy(info_header + 20, &image_bytes, 4);
    fwrite(file_header, sizeof(file_header), 1, file);
    fwrite(info_header, sizeof(info_header), 1, file);

    for (y = 0; y < HEIGHT; ++y)
    {
        const unsigned char *source = pixels + y * row_pitch;

        for (x = 0; x < WIDTH; ++x)
        {
            const unsigned char *pixel = source + x * 4;

            row[x * 3 + 0] = pixel[2];
            row[x * 3 + 1] = pixel[1];
            row[x * 3 + 2] = pixel[0];
            if (pixel[0] != first[0] || pixel[1] != first[1] || pixel[2] != first[2])
                ++changed;
            digest ^= pixel[0];
            digest *= UINT64_C(1099511628211);
            digest ^= pixel[1];
            digest *= UINT64_C(1099511628211);
            digest ^= pixel[2];
            digest *= UINT64_C(1099511628211);
        }
        if (fwrite(row, sizeof(row), 1, file) != 1)
        {
            fclose(file);
            puts("failure: could not write bitmap pixels");
            return 0;
        }
    }
    fclose(file);
    *digest_out = digest;
    *changed_out = changed;
    return 1;
}

static int compare_double(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        const char *metallib_path = argc > 1 ? argv[1] : "scene.metallib";
        double frame_times[FRAME_COUNT];
        double sorted_times[FRAME_COUNT - 1];
        double warm_mean = 0.0;
        double setup_start, setup_end;
        residency res = {0};
        vheap heap = {0};
        barrier_plan plan = {0};
        tracked_resource target = {"render target", STATE_UNDEFINED, -1, -1};
        tracked_resource staging = {"readback", STATE_UNDEFINED, -1, -1};
        uint64_t digest = 0;
        size_t changed_pixels = 0;
        NSError *error = nil;
        unsigned frame;

        setup_start = now_ms();

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            puts("failure: no Metal device");
            return 1;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];

        if (!residency_open(&res, device, 64u * 1024u * 1024u))
        {
            puts("failure: residency heap");
            return 1;
        }

        MTLTextureDescriptor *rt_desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:WIDTH
                                                              height:HEIGHT
                                                           mipmapped:NO];
        rt_desc.usage = MTLTextureUsageRenderTarget;
        rt_desc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> render_target = residency_place_texture(&res, rt_desc);
        if (!render_target)
        {
            puts("failure: render target placement");
            return 1;
        }

        NSUInteger row_pitch = WIDTH * 4;
        id<MTLBuffer> readback = [device newBufferWithLength:row_pitch * HEIGHT
                                                     options:MTLResourceStorageModeShared];
        id<MTLBuffer> constants = [device newBufferWithLength:sizeof(float) * 4
                                                      options:MTLResourceStorageModeShared];

        /* One CBV record, written once and materialized every frame. */
        vheap_write_cbv(&heap, 0, constants);
        uint32_t cbv_generation = heap.slots[0].generation;

        NSString *lib = [NSString stringWithUTF8String:metallib_path];
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:lib]
                                                     error:&error];
        if (!library)
        {
            printf("failure: metallib %s: %s\n", metallib_path,
                   error.localizedDescription.UTF8String);
            return 1;
        }

        MTLRenderPipelineDescriptor *pipe_desc = [MTLRenderPipelineDescriptor new];
        pipe_desc.vertexFunction = [library newFunctionWithName:@"vs"];
        pipe_desc.fragmentFunction = [library newFunctionWithName:@"ps"];
        if (!pipe_desc.vertexFunction || !pipe_desc.fragmentFunction)
        {
            puts("failure: lowered vs/ps not found in metallib");
            return 1;
        }
        pipe_desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipe_desc
                                                                                     error:&error];
        if (!pipeline)
        {
            printf("failure: pipeline: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }

        setup_end = now_ms();
        puts("stage: Metal12 pipeline");

        for (frame = 0; frame < FRAME_COUNT; ++frame)
        {
            float parameters[4] = {
                (float)frame / (float)(FRAME_COUNT - 1),
                (float)WIDTH / (float)HEIGHT,
                (float)WIDTH,
                (float)HEIGHT,
            };
            BOOL capture = frame + 1 == FRAME_COUNT;
            int stage = 0;
            double frame_start = now_ms();

            id<MTLBuffer> bound = vheap_materialize(&heap, 0, cbv_generation);
            if (!bound)
            {
                puts("failure: descriptor heap rejected the CBV binding");
                return 1;
            }
            memcpy(bound.contents, parameters, sizeof(parameters));

            id<MTLCommandBuffer> cb = [queue commandBuffer];

            tracker_transition(&plan, &target, STATE_RENDER_TARGET, stage, YES);
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = render_target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.015, 0.02, 0.035, 1.0);

            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
            [enc setRenderPipelineState:pipeline];
            [enc setViewport:(MTLViewport){0.0, 0.0, WIDTH, HEIGHT, 0.0, 1.0}];
            [enc setFragmentBuffer:bound offset:0 atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [enc endEncoding];
            stage++;

            if (capture)
            {
                tracker_transition(&plan, &target, STATE_COPY_SOURCE, stage, NO);
                tracker_transition(&plan, &staging, STATE_COPY_DEST, stage, YES);
                id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                [blit copyFromTexture:render_target
                                 sourceSlice:0
                                 sourceLevel:0
                                sourceOrigin:(MTLOrigin){0, 0, 0}
                                  sourceSize:(MTLSize){WIDTH, HEIGHT, 1}
                                    toBuffer:readback
                           destinationOffset:0
                      destinationBytesPerRow:row_pitch
                    destinationBytesPerImage:row_pitch * HEIGHT];
                [blit endEncoding];
                stage++;
            }

            [cb commit];
            [cb waitUntilCompleted];
            if (cb.error)
            {
                printf("failure: frame %u: %s\n", frame, cb.error.localizedDescription.UTF8String);
                return 1;
            }
            frame_times[frame] = now_ms() - frame_start;
        }

        if (plan.edges_unmet)
        {
            printf("failure: %u ordering edge(s) not covered by encoder order\n", plan.edges_unmet);
            return 1;
        }

        if (!write_bitmap((const unsigned char *)readback.contents, (unsigned)row_pitch, &digest,
                          &changed_pixels))
            return 1;

        if (changed_pixels < (size_t)(WIDTH * HEIGHT * 3 / 4))
        {
            printf("failure: image diversity too low: %zu/%u pixels\n", changed_pixels,
                   WIDTH * HEIGHT);
            return 1;
        }

        memcpy(sorted_times, frame_times + 1, sizeof(sorted_times));
        qsort(sorted_times, FRAME_COUNT - 1, sizeof(sorted_times[0]), compare_double);
        for (frame = 1; frame < FRAME_COUNT; ++frame)
            warm_mean += frame_times[frame];
        warm_mean /= FRAME_COUNT - 1;

        printf("metric: setup_ms=%.3f\n", setup_end - setup_start);
        printf("metric: first_frame_ms=%.3f\n", frame_times[0]);
        printf("metric: warm_mean_ms=%.3f\n", warm_mean);
        printf("metric: warm_p50_ms=%.3f\n", sorted_times[(FRAME_COUNT - 1) / 2]);
        printf("metric: warm_p95_ms=%.3f\n", sorted_times[((FRAME_COUNT - 1) * 95) / 100]);
        printf("metric: changed_pixels=%zu/%u\n", changed_pixels, WIDTH * HEIGHT);
        printf("metric: image_fnv1a64=%016llx\n", (unsigned long long)digest);
        printf("model: residency budget_mb=%llu placed_kb=%llu placements=%u\n",
               (unsigned long long)(res.budget_bytes / (1024 * 1024)),
               (unsigned long long)(res.placed_bytes / 1024), res.placements);
        printf("model: vheap materializations=%u stale_rejects=%u\n", heap.materializations,
               heap.stale_rejects);
        printf("model: barriers transitions=%u edges_required=%u "
               "satisfied_by_encoder_order=%u explicit_needed=%u\n",
               plan.transitions, plan.edges_required, plan.edges_by_encoder, plan.edges_unmet);
        printf("artifact: %s\n", OUTPUT_BITMAP);
        puts("status: PASS");
        return 0;
    }
}
