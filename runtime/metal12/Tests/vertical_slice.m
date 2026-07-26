/*
 * Alloy Metal12 reference-scene client.
 * Author: Timur Isaev
 *
 * Scene data and assertions live here; every runtime operation goes through
 * the public AlloyMetal12.h command surface.
 */

#import "../include/AlloyMetal12.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WIDTH 640u
#define HEIGHT 360u
#define FRAME_COUNT 120u
#define EXPECTED_DIGEST UINT64_C(0x44709706809f28e9)
#define EXPECTED_CHANGED_PIXELS 230397u

typedef struct Arguments
{
    const char *metallib;
    const char *output;
    const char *capture;
    BOOL present;
} Arguments;

static double NowMilliseconds(void)
{
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1.0e6;
}

static int ParseArguments(int argc, const char **argv, Arguments *arguments)
{
    if (argc < 2)
        return 0;
    arguments->metallib = argv[1];
    arguments->output = "m12-metal12-slice.bmp";
    for (int index = 2; index < argc; index++)
    {
        if (!strcmp(argv[index], "--output") && index + 1 < argc)
            arguments->output = argv[++index];
        else if (!strcmp(argv[index], "--capture") && index + 1 < argc)
            arguments->capture = argv[++index];
        else if (!strcmp(argv[index], "--present"))
            arguments->present = YES;
        else
            return 0;
    }
    return 1;
}

static CAMetalLayer *CreatePresentationLayer(NSWindow **windowOut)
{
    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSRect frame = NSMakeRect(100.0, 100.0, WIDTH, HEIGHT);
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.title = @"Alloy Metal12 Reference";
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, WIDTH, HEIGHT)];
    CAMetalLayer *layer = [CAMetalLayer layer];
    view.wantsLayer = YES;
    view.layer = layer;
    window.contentView = view;
    [window makeKeyAndOrderFront:nil];
    [application activateIgnoringOtherApps:NO];
    *windowOut = window;
    return layer;
}

static void PumpWindowEvents(void)
{
    NSApplication *application = NSApplication.sharedApplication;
    NSEvent *event;
    while ((event = [application nextEventMatchingMask:NSEventMaskAny
                                             untilDate:[NSDate date]
                                                inMode:NSDefaultRunLoopMode
                                               dequeue:YES]))
        [application sendEvent:event];
}

static void PrintMetrics(const AM12Metrics *metrics, BOOL presented)
{
    printf("mode: %s\n", presented ? "CAMetalLayer presentation" : "offscreen");
    printf("metric: setup_ms=%.3f\n", metrics->setup_ms);
    printf("metric: first_frame_ms=%.3f\n", metrics->first_frame_ms);
    printf("metric: warm_mean_ms=%.3f\n", metrics->warm_mean_ms);
    printf("metric: warm_p50_ms=%.3f\n", metrics->warm_p50_ms);
    printf("metric: warm_p95_ms=%.3f\n", metrics->warm_p95_ms);
    printf("metric: changed_pixels=%zu/%u\n", metrics->changed_pixels, WIDTH * HEIGHT);
    printf("metric: image_fnv1a64=%016llx\n", (unsigned long long)metrics->image_digest);
    printf("model: residency budget_mb=%llu placed_kb=%llu placements=%u\n",
           (unsigned long long)(metrics->residency_budget_bytes / (1024u * 1024u)),
           (unsigned long long)(metrics->residency_placed_bytes / 1024u),
           metrics->residency_placements);
    printf("model: vheap materializations=%u stale_rejects=%u\n",
           metrics->descriptor_materializations, metrics->descriptor_stale_rejects);
    printf("model: barriers transitions=%u edges_required=%u "
           "satisfied_by_encoder_order=%u explicit_needed=%u\n",
           metrics->barrier_transitions, metrics->barrier_edges_required,
           metrics->barrier_edges_by_encoder, metrics->barrier_edges_unmet);
    printf("presentation: frames=%u drawable_readbacks=%u pixel_authority=%s\n",
           metrics->presented_frames, metrics->drawable_readbacks,
           presented ? "final drawable" : "offscreen render target");
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        Arguments arguments = {0};
        if (!ParseArguments(argc, argv, &arguments))
        {
            puts("usage: vertical_slice <scene.metallib> [--output FILE] "
                 "[--capture TRACE] [--present]");
            return 2;
        }

        double setupStart = NowMilliseconds();
        NSWindow *window = nil;
        CAMetalLayer *layer = arguments.present ? CreatePresentationLayer(&window) : nil;
        AM12DeviceDescriptor descriptor = {
            .width = WIDTH,
            .height = HEIGHT,
            .frame_count = FRAME_COUNT,
            .metallib_path = arguments.metallib,
            .capture_path = arguments.capture,
            .presentation_layer = layer,
        };
        AM12Device *device = AM12CreateDevice(&descriptor);
        if (!device)
            return 1;

        AM12Resource target = AM12CreateRenderTarget(device);
        AM12Resource readback = AM12CreateSharedBuffer(device, WIDTH * HEIGHT * 4u);
        AM12Resource constants = AM12CreateSharedBuffer(device, sizeof(float) * 4u);
        uint32_t generation = AM12CreateConstantBufferView(device, 0, constants);
        if (!target || !readback || !constants || !generation ||
            !AM12CreateGraphicsPipeline(device, "vs", "ps"))
        {
            AM12DestroyDevice(device);
            return 1;
        }

        double setupMilliseconds = NowMilliseconds() - setupStart;
        AM12ResourceState targetState = AM12_RESOURCE_STATE_UNDEFINED;
        AM12ResourceState readbackState = AM12_RESOURCE_STATE_UNDEFINED;
        const float clear[4] = {0.015f, 0.02f, 0.035f, 1.0f};
        for (uint32_t frame = 0; frame < FRAME_COUNT; frame++)
        {
            float parameters[4] = {
                (float)frame / (float)(FRAME_COUNT - 1u),
                (float)WIDTH / (float)HEIGHT,
                (float)WIDTH,
                (float)HEIGHT,
            };
            BOOL capture = frame + 1u == FRAME_COUNT;
            if (window)
                PumpWindowEvents();
            if (!AM12BeginFrame(device, frame) ||
                !AM12WriteResource(device, constants, 0, parameters, sizeof(parameters)) ||
                !AM12SetGraphicsRootDescriptorTable(device, 0, generation) ||
                !AM12TransitionResource(device, target, targetState,
                                        AM12_RESOURCE_STATE_RENDER_TARGET) ||
                !AM12ClearRenderTarget(device, target, clear) ||
                !AM12DrawInstanced(device, target, 3, 1))
            {
                AM12DestroyDevice(device);
                return 1;
            }
            targetState = AM12_RESOURCE_STATE_RENDER_TARGET;

            if (capture)
            {
                if (!AM12TransitionResource(device, target, targetState,
                                            AM12_RESOURCE_STATE_COPY_SOURCE) ||
                    !AM12TransitionResource(device, readback, readbackState,
                                            AM12_RESOURCE_STATE_COPY_DESTINATION) ||
                    !AM12CopyTextureToBuffer(device, target, readback))
                {
                    AM12DestroyDevice(device);
                    return 1;
                }
                targetState = AM12_RESOURCE_STATE_COPY_SOURCE;
                readbackState = AM12_RESOURCE_STATE_COPY_DESTINATION;
            }
            if (!AM12Present(device, target) || !AM12EndFrame(device))
            {
                AM12DestroyDevice(device);
                return 1;
            }
        }

        AM12Metrics metrics = {0};
        if (!AM12WriteBitmapAndMeasure(device, readback, arguments.output, &metrics) ||
            !AM12FinishCapture(device))
        {
            AM12DestroyDevice(device);
            return 1;
        }
        metrics.setup_ms = setupMilliseconds;
        PrintMetrics(&metrics, arguments.present);
        printf("artifact: %s\n", arguments.output);

        int result = 0;
        if (metrics.image_digest != EXPECTED_DIGEST ||
            metrics.changed_pixels != EXPECTED_CHANGED_PIXELS ||
            metrics.descriptor_materializations != FRAME_COUNT ||
            metrics.descriptor_stale_rejects != 0 || metrics.barrier_transitions != 122 ||
            metrics.barrier_edges_required != 1 || metrics.barrier_edges_unmet != 0 ||
            (arguments.present &&
             (metrics.presented_frames != FRAME_COUNT || metrics.drawable_readbacks != 1)) ||
            (!arguments.present &&
             (metrics.presented_frames != 0 || metrics.drawable_readbacks != 0)))
        {
            puts("status: FAIL (reference threshold)");
            result = 1;
        }
        else
            puts("status: PASS");

        AM12DestroyDevice(device);
        [window close];
        return result;
    }
}
