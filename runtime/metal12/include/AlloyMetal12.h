/*
 * Alloy Metal12 public API.
 * Author: Timur Isaev
 */

#ifndef ALLOY_METAL12_H
#define ALLOY_METAL12_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __OBJC__
@class CAMetalLayer;
typedef CAMetalLayer *AM12MetalLayerRef;
#else
typedef void *AM12MetalLayerRef;
#endif

#ifdef __cplusplus
extern "C"
{
#endif

#define AM12_TRACE_FORMAT_MAJOR 1u
#define AM12_TRACE_FORMAT_MINOR 0u
#define AM12_MAX_RESOURCES 64u
#define AM12_MAX_DESCRIPTOR_SLOTS 256u
#define AM12_MAX_TRACE_BYTES (256u * 1024u * 1024u)
#define AM12_MAX_METALLIB_BYTES (64u * 1024u * 1024u)
#define AM12_MAX_IMAGE_BYTES (256u * 1024u * 1024u)
#define AM12_MAX_BUFFER_BYTES (256u * 1024u * 1024u)
#define AM12_MAX_DIMENSION 16384u
#define AM12_MAX_FRAMES 10000u
#define AM12_MAX_TRACE_RECORDS 1000000u
#define AM12_MAX_ENTRY_NAME_BYTES 1024u

    typedef struct AM12Device AM12Device;
    typedef uint32_t AM12Resource;

    typedef enum AM12ResourceState
    {
        AM12_RESOURCE_STATE_UNDEFINED = 0,
        AM12_RESOURCE_STATE_RENDER_TARGET = 1,
        AM12_RESOURCE_STATE_COPY_SOURCE = 2,
        AM12_RESOURCE_STATE_COPY_DESTINATION = 3,
        AM12_RESOURCE_STATE_CONSTANT_BUFFER = 4,
    } AM12ResourceState;

    typedef struct AM12DeviceDescriptor
    {
        uint32_t width;
        uint32_t height;
        uint32_t frame_count;
        const char *metallib_path;
        const char *capture_path;
        AM12MetalLayerRef presentation_layer;
    } AM12DeviceDescriptor;

    typedef struct AM12Metrics
    {
        double setup_ms;
        double first_frame_ms;
        double warm_mean_ms;
        double warm_p50_ms;
        double warm_p95_ms;
        uint64_t image_digest;
        size_t changed_pixels;
        uint64_t residency_budget_bytes;
        uint64_t residency_placed_bytes;
        uint32_t residency_placements;
        uint32_t descriptor_materializations;
        uint32_t descriptor_stale_rejects;
        uint32_t barrier_transitions;
        uint32_t barrier_edges_required;
        uint32_t barrier_edges_by_encoder;
        uint32_t barrier_edges_unmet;
        uint32_t presented_frames;
        uint32_t drawable_readbacks;
    } AM12Metrics;

    typedef struct AM12ReplaySummary
    {
        uint32_t runs;
        uint32_t stable_runs;
        uint64_t image_digest;
        /* Only the five timing members are populated in this aggregate. */
        AM12Metrics mean_timings;
        AM12Metrics last_run;
    } AM12ReplaySummary;

    /*
     * Describes one deterministic shader-proof dispatch. Zero texture fields
     * mean that the dispatch has no texture; otherwise all three texture
     * fields must be nonzero and describe a legal 2D mip chain.
     */
    typedef struct AM12ShaderProofConfiguration
    {
        uint32_t thread_count;
        uint32_t threads_per_threadgroup;
        uint32_t thread_execution_width;
        uint32_t texture_width;
        uint32_t texture_height;
        uint32_t texture_mip_levels;
    } AM12ShaderProofConfiguration;

    /*
     * Minimal D3D12-shaped command surface for the first runtime increment.
     * Resource handles and descriptor generations are trace-stable identifiers.
     */
    AM12Device *AM12CreateDevice(const AM12DeviceDescriptor *descriptor);
    /*
     * Flushes, synchronizes, closes, and atomically publishes a capture.
     * Destruction also attempts finalization, but this API reports failures.
     */
    int AM12FinishCapture(AM12Device *device);
    void AM12DestroyDevice(AM12Device *device);

    AM12Resource AM12CreateRenderTarget(AM12Device *device);
    AM12Resource AM12CreateSharedBuffer(AM12Device *device, size_t size);
    int AM12WriteResource(AM12Device *device, AM12Resource resource, size_t offset,
                          const void *bytes, size_t size);
    int AM12CreateGraphicsPipeline(AM12Device *device, const char *vertex_function,
                                   const char *fragment_function);

    uint32_t AM12CreateConstantBufferView(AM12Device *device, uint32_t slot, AM12Resource buffer);
    int AM12SetGraphicsRootDescriptorTable(AM12Device *device, uint32_t slot, uint32_t generation);

    int AM12BeginFrame(AM12Device *device, uint32_t frame_index);
    int AM12TransitionResource(AM12Device *device, AM12Resource resource, AM12ResourceState before,
                               AM12ResourceState after);
    int AM12ClearRenderTarget(AM12Device *device, AM12Resource target, const float color[4]);
    int AM12DrawInstanced(AM12Device *device, AM12Resource target, uint32_t vertex_count,
                          uint32_t instance_count);
    int AM12CopyTextureToBuffer(AM12Device *device, AM12Resource source, AM12Resource destination);
    int AM12Present(AM12Device *device, AM12Resource source);
    int AM12EndFrame(AM12Device *device);

    int AM12WriteBitmapAndMeasure(AM12Device *device, AM12Resource readback, const char *path,
                                  AM12Metrics *metrics);
    int AM12FinishMetrics(AM12Device *device, AM12Metrics *metrics);

    /*
     * Replays a self-contained trace without scene code. Repeated runs overwrite
     * the same deterministic bitmap and fail if any digest diverges.
     */
    int AM12ReplayTrace(const char *trace_path, const char *bitmap_path,
                        AM12MetalLayerRef presentation_layer, uint32_t repeat_count,
                        AM12ReplaySummary *summary);

    /*
     * Performs the complete, side-effect-free structural and semantic replay
     * preflight. No Metal objects or temporary metallib are created.
     */
    int AM12ValidateTrace(const char *trace_path);

    /*
     * Validates the dispatch and optional texture shape used by the shader
     * corpus before Metal command encoding.
     */
    int AM12ValidateShaderProofConfiguration(const AM12ShaderProofConfiguration *configuration);

    /* Original proof thresholds, promoted into and linked from this library. */
    int AM12RunDescriptorHeapProof(void);
    int AM12RunBarrierTrackerProof(void);
    int AM12RunResidencyProof(void);

#ifdef __cplusplus
}
#endif

#endif
