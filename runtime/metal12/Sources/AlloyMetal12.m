/*
 * Alloy Metal12 first runtime increment.
 * Author: Timur Isaev
 *
 * This is an original D3D12-shaped command layer over public Metal APIs. It
 * intentionally implements only the command subset exercised by the Phase-1
 * reference trace. See ../PROVENANCE.md and ADR-0012.
 */

#import "../include/AlloyMetal12.h"
#import "Models/AM12BarrierTracker.h"
#import "Models/AM12DescriptorHeap.h"
#import "Models/AM12ResidencyManager.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define AM12_HEAP_BYTES (64u * 1024u * 1024u)
#define AM12_RUNTIME_BARRIER_ACCESSES AM12_MAX_BARRIER_ACCESSES_PER_FRAME
#define AM12_RUNTIME_BARRIER_EDGES (AM12_RUNTIME_BARRIER_ACCESSES * AM12_RUNTIME_BARRIER_ACCESSES)
#define AM12_RUNTIME_DRAWABLE_RESOURCE AM12_MAX_RESOURCES
#define AM12_FNV_OFFSET UINT64_C(1469598103934665603)
#define AM12_FNV_PRIME UINT64_C(1099511628211)

typedef enum AM12TraceOpcode
{
    AM12_TRACE_DEVICE = 1,
    AM12_TRACE_METALLIB = 2,
    AM12_TRACE_CREATE_TEXTURE = 3,
    AM12_TRACE_CREATE_BUFFER = 4,
    AM12_TRACE_WRITE_RESOURCE = 5,
    AM12_TRACE_CREATE_PIPELINE = 6,
    AM12_TRACE_CREATE_CBV = 7,
    AM12_TRACE_SET_ROOT_TABLE = 8,
    AM12_TRACE_BEGIN_FRAME = 9,
    AM12_TRACE_TRANSITION = 10,
    AM12_TRACE_CLEAR = 11,
    AM12_TRACE_DRAW = 12,
    AM12_TRACE_COPY = 13,
    AM12_TRACE_PRESENT = 14,
    AM12_TRACE_END_FRAME = 15,
    AM12_TRACE_OUTPUT = 16,
} AM12TraceOpcode;

#pragma pack(push, 1)
typedef struct AM12TraceHeader
{
    char magic[8];
    uint16_t major;
    uint16_t minor;
    uint32_t header_size;
    uint32_t byte_order;
} AM12TraceHeader;

typedef struct AM12TraceRecordHeader
{
    uint16_t opcode;
    uint16_t flags;
    uint32_t payload_size;
} AM12TraceRecordHeader;

typedef struct AM12TraceDevice
{
    uint32_t width;
    uint32_t height;
    uint32_t frame_count;
} AM12TraceDevice;

typedef struct AM12TraceCreateResource
{
    uint32_t resource;
    uint64_t size;
} AM12TraceCreateResource;

typedef struct AM12TraceWriteResource
{
    uint32_t resource;
    uint64_t offset;
    uint64_t size;
} AM12TraceWriteResource;

typedef struct AM12TraceCreateCBV
{
    uint32_t slot;
    uint32_t resource;
    uint32_t generation;
} AM12TraceCreateCBV;

typedef struct AM12TraceRootTable
{
    uint32_t slot;
    uint32_t generation;
} AM12TraceRootTable;

typedef struct AM12TraceFrame
{
    uint32_t frame_index;
} AM12TraceFrame;

typedef struct AM12TraceTransition
{
    uint32_t resource;
    uint32_t before;
    uint32_t after;
} AM12TraceTransition;

typedef struct AM12TraceClear
{
    uint32_t resource;
    float color[4];
} AM12TraceClear;

typedef struct AM12TraceDraw
{
    uint32_t resource;
    uint32_t vertex_count;
    uint32_t instance_count;
} AM12TraceDraw;

typedef struct AM12TraceCopy
{
    uint32_t source;
    uint32_t destination;
} AM12TraceCopy;

typedef struct AM12TraceResourceOnly
{
    uint32_t resource;
} AM12TraceResourceOnly;

typedef struct AM12TracePipeline
{
    uint16_t vertex_length;
    uint16_t fragment_length;
} AM12TracePipeline;
#pragma pack(pop)

typedef enum AM12ResourceKind
{
    AM12_RESOURCE_TEXTURE,
    AM12_RESOURCE_BUFFER,
} AM12ResourceKind;

typedef struct AM12TracePlan AM12TracePlan;
static BOOL AM12PreflightTrace(NSData *traceData, AM12TracePlan *plan, NSString **detail);

static BOOL AM12ResourceStateAllowed(AM12ResourceKind kind, uint32_t state)
{
    if (state == AM12_RESOURCE_STATE_UNDEFINED)
        return YES;
    if (kind == AM12_RESOURCE_TEXTURE)
        return state == AM12_RESOURCE_STATE_RENDER_TARGET ||
               state == AM12_RESOURCE_STATE_COPY_SOURCE;
    return state == AM12_RESOURCE_STATE_COPY_DESTINATION ||
           state == AM12_RESOURCE_STATE_CONSTANT_BUFFER;
}

@interface AM12ResourceEntry : NSObject
@property(nonatomic) AM12Resource identifier;
@property(nonatomic) AM12ResourceKind kind;
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) id<MTLBuffer> buffer;
@property(nonatomic, strong) AM12ResidencyLease *residencyLease;
@property(nonatomic) BOOL contentsDefined;
@end

@implementation AM12ResourceEntry
@end

@interface AM12DeviceBox : NSObject
{
  @public
    AM12BarrierPlan barrierPlan;
    AM12BarrierEdge barrierEdges[AM12_RUNTIME_BARRIER_EDGES];
    uint32_t barrierAccessEncoders[AM12_RUNTIME_BARRIER_ACCESSES];
    uint32_t barrierEncoderWaitMasks[AM12_RUNTIME_BARRIER_ACCESSES];
    bool barrierEncoderSignaled[AM12_RUNTIME_BARRIER_ACCESSES];
}
@property(nonatomic, strong) id<MTLDevice> metal;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) NSMutableArray<id<MTLFence>> *barrierFences;
@property(nonatomic, strong) AM12DescriptorHeap *descriptorHeap;
@property(nonatomic) AM12BarrierTracker *barrierTracker;
@property(nonatomic, strong) AM12ResidencyManager *residencyManager;
@property(nonatomic, strong) id<MTLLibrary> library;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, AM12ResourceEntry *> *resources;
@property(nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property(nonatomic, strong) id<CAMetalDrawable> drawable;
@property(nonatomic, strong) dispatch_semaphore_t finalPresentationSignal;
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic, strong) NSData *libraryData;
@property(nonatomic) uint32_t width;
@property(nonatomic) uint32_t height;
@property(nonatomic) uint32_t frameCount;
@property(nonatomic) uint32_t nextResource;
@property(nonatomic) AM12Resource boundConstantBuffer;
@property(nonatomic, strong) id<MTLBuffer> boundDescriptorPage;
@property(nonatomic) AM12Resource clearTarget;
@property(nonatomic) MTLClearColor clearColor;
@property(nonatomic) BOOL clearReady;
@property(nonatomic) BOOL drewThisFrame;
@property(nonatomic) BOOL presentedThisFrame;
@property(nonatomic) uint32_t encoderOrdinal;
@property(nonatomic) double setupStart;
@property(nonatomic) double setupEnd;
@property(nonatomic) double frameStart;
@property(nonatomic) double *frameTimes;
@property(nonatomic) uint32_t measuredFrames;
@property(nonatomic) uint64_t imageDigest;
@property(nonatomic) size_t changedPixels;
@property(nonatomic) uint64_t residencyNextOffset;
@property(nonatomic) uint64_t sharedBufferBytes;
@property(nonatomic) uint32_t descriptorStaleRejects;
@property(nonatomic) uint32_t barrierTransitions;
@property(nonatomic) uint32_t barrierEdgesRequired;
@property(nonatomic) uint32_t barrierEdgesEmitted;
@property(nonatomic) uint32_t barrierEdgesUnmet;
@property(nonatomic) AM12Resource pendingPresentationReadback;
@property(nonatomic) uint32_t presentedFrames;
@property(nonatomic) uint32_t drawableReadbacks;
@property(nonatomic) FILE *traceFile;
@property(nonatomic) BOOL traceFailed;
@property(nonatomic) BOOL captureRequested;
@property(nonatomic) BOOL traceFinalized;
@property(nonatomic) BOOL traceOutputRecorded;
@property(nonatomic, copy) NSString *traceFinalPath;
@property(nonatomic, copy) NSString *traceTemporaryPath;
@property(nonatomic) size_t traceBytesWritten;
@property(nonatomic) uint32_t traceRecordCount;
@end

@implementation AM12DeviceBox

- (void)dealloc
{
    AM12BarrierTrackerDestroy(_barrierTracker);
    free(_frameTimes);
}

@end

struct AM12Device
{
    void *box;
};

static double AM12NowMilliseconds(void)
{
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1.0e6;
}

static AM12DeviceBox *AM12Box(AM12Device *device)
{
    return device ? (__bridge AM12DeviceBox *)device->box : nil;
}

static int AM12Failure(const char *operation, NSString *detail)
{
    fprintf(stderr, "AM12 failure: %s%s%s\n", operation, detail ? ": " : "",
            detail ? detail.UTF8String : "");
    return 0;
}

static AM12ResourceEntry *AM12FindResource(AM12DeviceBox *box, AM12Resource resource,
                                           AM12ResourceKind kind)
{
    AM12ResourceEntry *entry = box.resources[@(resource)];

    if (!entry || entry.kind != kind)
        return nil;
    return entry;
}

static BOOL AM12CheckedAlignSize(size_t value, size_t alignment, size_t *result)
{
    if (!alignment || !result)
        return NO;
    size_t remainder = value % alignment;
    size_t addition = remainder ? alignment - remainder : 0;
    if (addition > SIZE_MAX - value)
        return NO;
    *result = value + addition;
    return YES;
}

static BOOL AM12ResourceHasState(AM12DeviceBox *box, AM12Resource resource,
                                 AM12ResourceState expected)
{
    uint32_t state = 0;
    return box && box.barrierTracker &&
           AM12BarrierTrackerGetState(box.barrierTracker, resource, AM12_BARRIER_ALL_SUBRESOURCES,
                                      &state) &&
           state == expected;
}

static BOOL AM12PrepareBarrierEncoder(AM12DeviceBox *box, const AM12BarrierAccess *accesses,
                                      uint32_t accessCount, uint32_t *encoderOrdinal,
                                      uint32_t *waitMask)
{
    if (!box || !box.barrierTracker || box.barrierFences.count != AM12_RUNTIME_BARRIER_ACCESSES ||
        !accesses || !accessCount || !encoderOrdinal || !waitMask ||
        box.encoderOrdinal >= AM12_RUNTIME_BARRIER_ACCESSES)
        return NO;

    uint32_t firstAccess = 0;
    if (!AM12BarrierTrackerRecordAccessBatch(box.barrierTracker, accesses, accessCount,
                                             &firstAccess))
        return NO;

    uint32_t currentEncoder = box.encoderOrdinal;
    for (uint32_t index = 0; index < accessCount; index++)
        box->barrierAccessEncoders[firstAccess + index] = currentEncoder;

    AM12BarrierVerification verification = {0};
    if (!AM12BarrierTrackerCompileOptimized(box.barrierTracker, &box->barrierPlan) ||
        !AM12BarrierTrackerVerifyPlan(box.barrierTracker, &box->barrierPlan, &verification) ||
        verification.uncovered_hazard_count)
        return NO;

    uint32_t waits = 0;
    uint32_t recordedAccessCount = AM12BarrierTrackerAccessCount(box.barrierTracker);
    for (uint32_t edgeIndex = 0; edgeIndex < box->barrierPlan.edge_count; edgeIndex++)
    {
        AM12BarrierEdge edge = box->barrierPlan.edges[edgeIndex];
        if (edge.from_access >= recordedAccessCount || edge.to_access >= recordedAccessCount)
            return NO;
        uint32_t fromEncoder = box->barrierAccessEncoders[edge.from_access];
        uint32_t toEncoder = box->barrierAccessEncoders[edge.to_access];
        if (toEncoder == currentEncoder)
        {
            if (fromEncoder >= currentEncoder)
                return NO;
            waits |= UINT32_C(1) << fromEncoder;
        }
    }

    *encoderOrdinal = currentEncoder;
    *waitMask = waits;
    return YES;
}

static void AM12CompleteBarrierEncoder(AM12DeviceBox *box, uint32_t encoderOrdinal,
                                       uint32_t waitMask)
{
    box->barrierEncoderWaitMasks[encoderOrdinal] = waitMask;
    box->barrierEncoderSignaled[encoderOrdinal] = true;
    box.encoderOrdinal = encoderOrdinal + 1u;
}

static BOOL AM12VerifyBarrierSubmission(AM12DeviceBox *box, AM12BarrierVerification *verification,
                                        uint32_t *mappedEdges, uint32_t *unmetEdges)
{
    if (!box || !verification || !mappedEdges || !unmetEdges ||
        !AM12BarrierTrackerCompileOptimized(box.barrierTracker, &box->barrierPlan) ||
        !AM12BarrierTrackerVerifyPlan(box.barrierTracker, &box->barrierPlan, verification))
        return NO;

    uint32_t accessCount = AM12BarrierTrackerAccessCount(box.barrierTracker);
    uint32_t mapped = 0;
    uint32_t unmet = (uint32_t)verification->uncovered_hazard_count;
    for (uint32_t edgeIndex = 0; edgeIndex < box->barrierPlan.edge_count; edgeIndex++)
    {
        AM12BarrierEdge edge = box->barrierPlan.edges[edgeIndex];
        if (edge.from_access >= accessCount || edge.to_access >= accessCount)
            return NO;
        uint32_t fromEncoder = box->barrierAccessEncoders[edge.from_access];
        uint32_t toEncoder = box->barrierAccessEncoders[edge.to_access];
        if (fromEncoder < toEncoder && box->barrierEncoderSignaled[fromEncoder] &&
            (box->barrierEncoderWaitMasks[toEncoder] & (UINT32_C(1) << fromEncoder)))
            mapped++;
        else
            unmet++;
    }

    *mappedEdges = mapped;
    *unmetEdges = unmet;
    return YES;
}

static BOOL AM12WriteAll(FILE *file, const void *bytes, size_t size)
{
    return size == 0 || fwrite(bytes, size, 1, file) == 1;
}

typedef struct AM12ImageLayout
{
    size_t rgbaRowBytes;
    size_t rgbaBytes;
    size_t bitmapRowBytes;
    size_t bitmapRowStride;
    size_t bitmapImageBytes;
    uint32_t bitmapFileBytes;
} AM12ImageLayout;

static BOOL AM12CheckedAddSize(size_t left, size_t right, size_t *result)
{
    if (right > SIZE_MAX - left)
        return NO;
    *result = left + right;
    return YES;
}

static BOOL AM12CheckedMultiplySize(size_t left, size_t right, size_t *result)
{
    if (left && right > SIZE_MAX / left)
        return NO;
    *result = left * right;
    return YES;
}

static BOOL AM12ComputeImageLayout(uint32_t width, uint32_t height, AM12ImageLayout *layout)
{
    AM12ImageLayout result = {0};
    size_t unalignedBitmapRow = 0;
    size_t bitmapFileBytes = 0;

    if (!width || !height || width > AM12_MAX_DIMENSION || height > AM12_MAX_DIMENSION ||
        !AM12CheckedMultiplySize(width, 4u, &result.rgbaRowBytes) ||
        !AM12CheckedMultiplySize(result.rgbaRowBytes, height, &result.rgbaBytes) ||
        result.rgbaBytes > AM12_MAX_IMAGE_BYTES ||
        !AM12CheckedMultiplySize(width, 3u, &unalignedBitmapRow) ||
        !AM12CheckedAddSize(unalignedBitmapRow, 3u, &result.bitmapRowBytes))
        return NO;

    result.bitmapRowStride = result.bitmapRowBytes & ~(size_t)3u;
    result.bitmapRowBytes = unalignedBitmapRow;
    if (!AM12CheckedMultiplySize(result.bitmapRowStride, height, &result.bitmapImageBytes) ||
        !AM12CheckedAddSize(54u, result.bitmapImageBytes, &bitmapFileBytes) ||
        bitmapFileBytes > UINT32_MAX)
        return NO;
    result.bitmapFileBytes = (uint32_t)bitmapFileBytes;
    if (layout)
        *layout = result;
    return YES;
}

static NSData *AM12ReadBoundedFile(const char *path, size_t maximumSize, NSString **detail)
{
    if (!path)
        return nil;
    int descriptor = open(path, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0)
    {
        if (detail)
            *detail = [NSString stringWithUTF8String:strerror(errno)];
        return nil;
    }
    struct stat status;
    if (fstat(descriptor, &status) || !S_ISREG(status.st_mode) || status.st_size <= 0 ||
        (uint64_t)status.st_size > maximumSize)
    {
        (void)close(descriptor);
        if (detail)
            *detail = @"file missing, empty, non-regular, or exceeds its size bound";
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    if (!data)
    {
        (void)close(descriptor);
        if (detail)
            *detail = @"file allocation failed";
        return nil;
    }

    size_t total = 0;
    while (total < data.length)
    {
        ssize_t count = read(descriptor, (uint8_t *)data.mutableBytes + total, data.length - total);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
        {
            (void)close(descriptor);
            if (detail)
                *detail = count < 0 ? [NSString stringWithUTF8String:strerror(errno)]
                                    : @"file was truncated while being read";
            return nil;
        }
        total += (size_t)count;
    }

    uint8_t extraByte = 0;
    ssize_t extraCount;
    do
    {
        extraCount = read(descriptor, &extraByte, sizeof(extraByte));
    } while (extraCount < 0 && errno == EINTR);
    struct stat finalStatus;
    int finalStatusResult = fstat(descriptor, &finalStatus);
    int closeResult = close(descriptor);
    if (extraCount != 0 || finalStatusResult || finalStatus.st_size != status.st_size ||
        closeResult)
    {
        if (detail)
            *detail = @"file changed or failed while being read";
        return nil;
    }
    return [data copy];
}

static BOOL AM12TraceRecord(AM12DeviceBox *box, AM12TraceOpcode opcode, const void *payload,
                            uint32_t payloadSize)
{
    if (!box.traceFile)
        return !box.captureRequested;
    if (box.traceFailed)
        return NO;

    size_t recordSize = 0;
    size_t nextSize = 0;
    if (box.traceRecordCount >= AM12_MAX_TRACE_RECORDS ||
        !AM12CheckedAddSize(sizeof(AM12TraceRecordHeader), payloadSize, &recordSize) ||
        !AM12CheckedAddSize(box.traceBytesWritten, recordSize, &nextSize) ||
        nextSize > AM12_MAX_TRACE_BYTES)
    {
        box.traceFailed = YES;
        return NO;
    }
    AM12TraceRecordHeader header = {
        .opcode = (uint16_t)opcode,
        .flags = 0,
        .payload_size = payloadSize,
    };
    if (!AM12WriteAll(box.traceFile, &header, sizeof(header)) ||
        !AM12WriteAll(box.traceFile, payload, payloadSize))
    {
        box.traceFailed = YES;
        return NO;
    }
    box.traceBytesWritten = nextSize;
    box.traceRecordCount++;
    return YES;
}

static BOOL AM12TraceRecordData(AM12DeviceBox *box, AM12TraceOpcode opcode, NSData *data)
{
    if (data.length > UINT32_MAX)
        return NO;
    return AM12TraceRecord(box, opcode, data.bytes, (uint32_t)data.length);
}

static BOOL AM12TraceVariableRecord(AM12DeviceBox *box, AM12TraceOpcode opcode, const void *prefix,
                                    size_t prefixSize, const void *bytes, size_t byteCount)
{
    size_t payloadSize = 0;
    size_t recordSize = 0;
    size_t finalSize = 0;
    BOOL invalid = !AM12CheckedAddSize(prefixSize, byteCount, &payloadSize) ||
                   payloadSize > UINT32_MAX ||
                   !AM12CheckedAddSize(sizeof(AM12TraceRecordHeader), payloadSize, &recordSize) ||
                   (box.captureRequested &&
                    (box.traceRecordCount >= AM12_MAX_TRACE_RECORDS ||
                     !AM12CheckedAddSize(box.traceBytesWritten, recordSize, &finalSize) ||
                     finalSize > AM12_MAX_TRACE_BYTES));
    if (invalid)
    {
        if (box.captureRequested)
            box.traceFailed = YES;
        return NO;
    }
    NSMutableData *payload = [NSMutableData dataWithCapacity:payloadSize];

    [payload appendBytes:prefix length:prefixSize];
    [payload appendBytes:bytes length:byteCount];
    return AM12TraceRecordData(box, opcode, payload);
}

static void AM12AbortCapture(AM12DeviceBox *box)
{
    FILE *file = box.traceFile;
    box.traceFile = NULL;
    if (file)
        (void)fclose(file);
    if (box.traceTemporaryPath)
        (void)unlink(box.traceTemporaryPath.fileSystemRepresentation);
}

static BOOL AM12StartCapture(AM12DeviceBox *box, const char *capturePath)
{
    NSString *finalPath = [NSString stringWithUTF8String:capturePath];
    if (!finalPath.length)
        return NO;
    NSString *temporaryPath =
        [finalPath stringByAppendingFormat:@".tmp.%@", NSUUID.UUID.UUIDString];
    int descriptor =
        open(temporaryPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0)
        return NO;
    FILE *file = fdopen(descriptor, "wb");
    if (!file)
    {
        int savedError = errno;
        (void)close(descriptor);
        (void)unlink(temporaryPath.fileSystemRepresentation);
        errno = savedError;
        return NO;
    }
    box.captureRequested = YES;
    box.traceFinalPath = finalPath;
    box.traceTemporaryPath = temporaryPath;
    box.traceFile = file;
    return YES;
}

AM12Device *AM12CreateDevice(const AM12DeviceDescriptor *descriptor)
{
    @autoreleasepool
    {
        AM12ImageLayout imageLayout;
        if (!descriptor || !descriptor->width || !descriptor->height || !descriptor->frame_count ||
            descriptor->frame_count > AM12_MAX_FRAMES || !descriptor->metallib_path ||
            !AM12ComputeImageLayout(descriptor->width, descriptor->height, &imageLayout))
        {
            AM12Failure("create device", @"invalid descriptor");
            return NULL;
        }

        NSString *fileDetail = nil;
        NSData *libraryData =
            AM12ReadBoundedFile(descriptor->metallib_path, AM12_MAX_METALLIB_BYTES, &fileDetail);
        if (!libraryData)
        {
            AM12Failure("load metallib", fileDetail);
            return NULL;
        }

        AM12DeviceBox *box = [AM12DeviceBox new];
        box.setupStart = AM12NowMilliseconds();
        box.width = descriptor->width;
        box.height = descriptor->height;
        box.frameCount = descriptor->frame_count;
        box.layer = descriptor->presentation_layer;
        box.nextResource = 1;
        box.resources = [NSMutableDictionary dictionary];
        box.frameTimes = calloc(box.frameCount, sizeof(*box.frameTimes));
        box.libraryData = libraryData;
        box.metal = MTLCreateSystemDefaultDevice();
        if (!box.frameTimes || !box.metal)
        {
            AM12Failure("create device", @"no Metal device or frame timing storage");
            return NULL;
        }
        if (@available(macOS 13.0, *))
        {
            if (box.metal.argumentBuffersSupport != MTLArgumentBuffersTier2)
            {
                AM12Failure("create device", @"descriptor pages require argument-buffer tier 2");
                return NULL;
            }
        }
        else
        {
            AM12Failure("create device", @"descriptor pages require macOS 13 or newer");
            return NULL;
        }
        box.queue = [box.metal newCommandQueue];
        AM12ResidencyPressurePolicy pressurePolicy = {
            .oversubscription_margin_bytes = UINT64_C(1) << 30,
            .bailout_floor_bytes = UINT64_C(2) << 30,
            .eviction_batch_count = 4,
        };
        box.residencyManager = [[AM12ResidencyManager alloc] initWithDevice:box.metal
                                                              cacheCapacity:12
                                                             pressurePolicy:pressurePolicy];

        id<MTLBuffer> descriptorPoison =
            [box.metal newBufferWithLength:16 options:MTLResourceStorageModeShared];
        if (descriptorPoison)
            *(uint32_t *)descriptorPoison.contents = UINT32_MAX;
        AM12DescriptorHeapConfiguration descriptorConfiguration = {
            .slot_count = AM12_MAX_DESCRIPTOR_SLOTS,
            .resource_capacity = AM12_MAX_RESOURCES,
            .page_entry_count = AM12_MAX_DESCRIPTOR_SLOTS,
            .page_count = 64,
            .invalid_resource_identifier = UINT32_MAX,
        };
        box.descriptorHeap = [[AM12DescriptorHeap alloc] initWithDevice:box.metal
                                                          configuration:descriptorConfiguration
                                                           poisonBuffer:descriptorPoison];

        AM12BarrierTrackerDescriptor barrierDescriptor = {
            .max_access_count = AM12_RUNTIME_BARRIER_ACCESSES,
            .memory_object_count = AM12_MAX_RESOURCES + 1u,
            .subresource_count = 1,
            .queue_count = 1,
        };
        box.barrierTracker = AM12BarrierTrackerCreate(&barrierDescriptor);
        box.barrierFences = [NSMutableArray arrayWithCapacity:AM12_RUNTIME_BARRIER_ACCESSES];
        for (uint32_t index = 0; index < AM12_RUNTIME_BARRIER_ACCESSES; index++)
        {
            id<MTLFence> fence = [box.metal newFence];
            if (!fence)
                break;
            [box.barrierFences addObject:fence];
        }
        BOOL barrierPlanReady = AM12BarrierPlanInitialize(&box->barrierPlan, box->barrierEdges,
                                                          AM12_RUNTIME_BARRIER_EDGES);

        NSError *modelError = nil;
        BOOL residencyReady = [box.residencyManager openPlacementHeapWithSize:AM12_HEAP_BYTES
                                                                  storageMode:MTLStorageModePrivate
                                                                        error:&modelError];
        if (!box.queue || !box.residencyManager || !residencyReady || !box.descriptorHeap ||
            !box.barrierTracker || box.barrierFences.count != AM12_RUNTIME_BARRIER_ACCESSES ||
            !barrierPlanReady)
        {
            AM12Failure("create device",
                        modelError.localizedDescription ?: @"runtime model initialization");
            return NULL;
        }
        if (box.layer)
        {
            box.layer.device = box.metal;
            box.layer.pixelFormat = MTLPixelFormatRGBA8Unorm;
            box.layer.framebufferOnly = NO;
            box.layer.drawableSize = CGSizeMake(box.width, box.height);
            box.layer.maximumDrawableCount = 2;
            box.layer.displaySyncEnabled = NO;
        }

        NSError *error = nil;
        NSData *retainedLibraryData = box.libraryData;
        dispatch_data_t metalLibraryData =
            dispatch_data_create(retainedLibraryData.bytes, retainedLibraryData.length,
                                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                                   (void)retainedLibraryData;
                                 });
        box.library = [box.metal newLibraryWithData:metalLibraryData error:&error];
        if (!box.library)
        {
            AM12Failure("load metallib", error.localizedDescription);
            return NULL;
        }

        if (descriptor->capture_path)
        {
            if (!AM12StartCapture(box, descriptor->capture_path))
            {
                AM12Failure("open trace", [NSString stringWithUTF8String:strerror(errno)]);
                return NULL;
            }
            AM12TraceHeader traceHeader = {
                .magic = {'A', 'M', '1', '2', 'T', 'R', 'C', '1'},
                .major = AM12_TRACE_FORMAT_MAJOR,
                .minor = AM12_TRACE_FORMAT_MINOR,
                .header_size = sizeof(AM12TraceHeader),
                .byte_order = UINT32_C(0x01020304),
            };
            AM12TraceDevice traceDevice = {
                .width = box.width,
                .height = box.height,
                .frame_count = box.frameCount,
            };
            if (!AM12WriteAll(box.traceFile, &traceHeader, sizeof(traceHeader)))
            {
                box.traceFailed = YES;
                AM12AbortCapture(box);
                AM12Failure("write trace header", nil);
                return NULL;
            }
            box.traceBytesWritten = sizeof(traceHeader);
            if (!AM12TraceRecord(box, AM12_TRACE_DEVICE, &traceDevice, sizeof(traceDevice)) ||
                !AM12TraceRecordData(box, AM12_TRACE_METALLIB, box.libraryData))
            {
                AM12AbortCapture(box);
                AM12Failure("write trace header", nil);
                return NULL;
            }
        }

        AM12Device *device = calloc(1, sizeof(*device));
        if (!device)
        {
            if (box.traceFile)
                AM12AbortCapture(box);
            AM12Failure("allocate device handle", nil);
            return NULL;
        }
        device->box = (__bridge_retained void *)box;
        return device;
    }
}

int AM12FinishCapture(AM12Device *device)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box)
        return AM12Failure("finish capture", @"invalid device");
    if (!box.captureRequested)
        return 1;
    if (box.traceFinalized)
        return box.traceFailed ? 0 : 1;
    if (box.commandBuffer)
        return AM12Failure("finish capture", @"frame is still active");
    if (!box.traceOutputRecorded)
        return AM12Failure("finish capture", @"output declaration has not been recorded");

    FILE *file = box.traceFile;
    box.traceFile = NULL;
    int failed = box.traceFailed || !file;
    if (file)
    {
        if (fflush(file))
            failed = 1;
        if (fsync(fileno(file)))
            failed = 1;
        if (fclose(file))
            failed = 1;
    }
    NSString *validationDetail = nil;
    if (!failed)
    {
        NSData *capture = AM12ReadBoundedFile(box.traceTemporaryPath.fileSystemRepresentation,
                                              AM12_MAX_TRACE_BYTES, &validationDetail);
        if (!capture || !AM12PreflightTrace(capture, NULL, &validationDetail))
            failed = 1;
    }
    if (!failed && rename(box.traceTemporaryPath.fileSystemRepresentation,
                          box.traceFinalPath.fileSystemRepresentation))
        failed = 1;
    if (failed && box.traceTemporaryPath)
        (void)unlink(box.traceTemporaryPath.fileSystemRepresentation);

    box.traceFailed = failed;
    box.traceFinalized = YES;
    return failed ? AM12Failure("finish capture",
                                validationDetail ?: @"flush, close, or atomic publish failed")
                  : 1;
}

void AM12DestroyDevice(AM12Device *device)
{
    if (!device)
        return;
    AM12DeviceBox *box = AM12Box(device);

    if (box.captureRequested && !box.traceFinalized)
    {
        if (!AM12FinishCapture(device))
        {
            AM12Failure("destroy device", @"capture was not published");
            AM12AbortCapture(box);
            box.traceFailed = YES;
            box.traceFinalized = YES;
        }
    }
    else if (box.traceFile)
    {
        AM12AbortCapture(box);
    }
    box.commandBuffer = nil;
    box.drawable = nil;
    box.pipeline = nil;
    box.library = nil;
    [box.resources removeAllObjects];
    box.descriptorHeap = nil;
    box.residencyManager = nil;
    box.barrierFences = nil;
    AM12BarrierTrackerDestroy(box.barrierTracker);
    box.barrierTracker = NULL;
    box.queue = nil;
    box.metal = nil;
    CFBridgingRelease(device->box);
    free(device);
}

AM12Resource AM12CreateRenderTarget(AM12Device *device)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box || box.commandBuffer || box.measuredFrames || box.nextResource >= AM12_MAX_RESOURCES)
        return 0;

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           width:box.width
                                                          height:box.height
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    MTLSizeAndAlign sizeAndAlign = [box.metal heapTextureSizeAndAlignWithDescriptor:descriptor];
    size_t placementOffset = 0;
    if (!AM12CheckedAlignSize((size_t)box.residencyNextOffset, sizeAndAlign.align,
                              &placementOffset) ||
        sizeAndAlign.size > AM12_HEAP_BYTES ||
        placementOffset > AM12_HEAP_BYTES - sizeAndAlign.size)
    {
        AM12Failure("create render target", @"residency heap bound");
        return 0;
    }
    NSError *residencyError = nil;
    AM12ResidencyLease *lease =
        [box.residencyManager newPlacedTextureWithDescriptor:descriptor
                                                      offset:placementOffset
                                                       error:&residencyError];
    id<MTLTexture> texture = (id<MTLTexture>)lease.resource;
    if (!lease || !texture)
    {
        AM12Failure("create render target", residencyError.localizedDescription);
        return 0;
    }

    AM12Resource resource = box.nextResource++;
    AM12ResourceEntry *entry = [AM12ResourceEntry new];
    entry.identifier = resource;
    entry.kind = AM12_RESOURCE_TEXTURE;
    entry.texture = texture;
    entry.residencyLease = lease;
    if (!AM12BarrierTrackerSetState(box.barrierTracker, resource, AM12_BARRIER_ALL_SUBRESOURCES,
                                    AM12_RESOURCE_STATE_UNDEFINED))
        return 0;
    box.resources[@(resource)] = entry;
    box.residencyNextOffset = placementOffset + sizeAndAlign.size;

    AM12TraceCreateResource record = {
        .resource = resource,
        .size = sizeAndAlign.size,
    };
    if (!AM12TraceRecord(box, AM12_TRACE_CREATE_TEXTURE, &record, sizeof(record)))
        return 0;
    return resource;
}

AM12Resource AM12CreateSharedBuffer(AM12Device *device, size_t size)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box || box.commandBuffer || box.measuredFrames || !size || size > AM12_MAX_BUFFER_BYTES ||
        box.sharedBufferBytes > AM12_MAX_BUFFER_BYTES - size ||
        box.nextResource >= AM12_MAX_RESOURCES)
        return 0;

    AM12ResidencyLease *lease =
        [box.residencyManager newCommittedBufferWithLength:size
                                                   options:MTLResourceStorageModeShared];
    id<MTLBuffer> buffer = (id<MTLBuffer>)lease.resource;
    if (!lease || !buffer)
    {
        AM12Failure("create shared buffer", nil);
        return 0;
    }
    AM12Resource resource = box.nextResource++;
    AM12ResourceEntry *entry = [AM12ResourceEntry new];
    entry.identifier = resource;
    entry.kind = AM12_RESOURCE_BUFFER;
    entry.buffer = buffer;
    entry.residencyLease = lease;
    memset(buffer.contents, 0, size);
    entry.contentsDefined = YES;
    if (![box.descriptorHeap registerBuffer:buffer forResourceIdentifier:resource] ||
        !AM12BarrierTrackerSetState(box.barrierTracker, resource, AM12_BARRIER_ALL_SUBRESOURCES,
                                    AM12_RESOURCE_STATE_UNDEFINED))
        return 0;
    box.resources[@(resource)] = entry;
    box.sharedBufferBytes += size;

    AM12TraceCreateResource record = {
        .resource = resource,
        .size = size,
    };
    if (!AM12TraceRecord(box, AM12_TRACE_CREATE_BUFFER, &record, sizeof(record)))
        return 0;
    return resource;
}

int AM12WriteResource(AM12Device *device, AM12Resource resource, size_t offset, const void *bytes,
                      size_t size)
{
    AM12DeviceBox *box = AM12Box(device);
    AM12ResourceEntry *entry = AM12FindResource(box, resource, AM12_RESOURCE_BUFFER);
    if (!box || !entry || !bytes || !size || offset > entry.buffer.length ||
        size > entry.buffer.length - offset)
        return AM12Failure("write resource", @"invalid buffer range");

    memcpy((uint8_t *)entry.buffer.contents + offset, bytes, size);
    entry.contentsDefined = YES;
    AM12TraceWriteResource record = {
        .resource = resource,
        .offset = offset,
        .size = size,
    };
    return AM12TraceVariableRecord(box, AM12_TRACE_WRITE_RESOURCE, &record, sizeof(record), bytes,
                                   size);
}

int AM12CreateGraphicsPipeline(AM12Device *device, const char *vertexFunction,
                               const char *fragmentFunction)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box || box.commandBuffer || box.measuredFrames || box.pipeline || !vertexFunction ||
        !fragmentFunction)
        return AM12Failure("create graphics pipeline", @"invalid arguments");
    size_t vertexLength = strnlen(vertexFunction, AM12_MAX_ENTRY_NAME_BYTES + 1u);
    size_t fragmentLength = strnlen(fragmentFunction, AM12_MAX_ENTRY_NAME_BYTES + 1u);
    if (!vertexLength || !fragmentLength || vertexLength > AM12_MAX_ENTRY_NAME_BYTES ||
        fragmentLength > AM12_MAX_ENTRY_NAME_BYTES)
        return AM12Failure("create graphics pipeline", @"entry name length");

    NSString *vertexName = [NSString stringWithUTF8String:vertexFunction];
    NSString *fragmentName = [NSString stringWithUTF8String:fragmentFunction];
    if (!vertexName || !fragmentName)
        return AM12Failure("create graphics pipeline", @"entry name is not valid UTF-8");
    id<MTLFunction> vertex = [box.library newFunctionWithName:vertexName];
    id<MTLFunction> fragment = [box.library newFunctionWithName:fragmentName];
    if (!vertex || !fragment)
        return AM12Failure("create graphics pipeline", @"entry function missing");

    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    NSError *error = nil;
    box.pipeline = [box.metal newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!box.pipeline)
        return AM12Failure("create graphics pipeline", error.localizedDescription);

    AM12TracePipeline record = {
        .vertex_length = (uint16_t)vertexLength,
        .fragment_length = (uint16_t)fragmentLength,
    };
    NSMutableData *payload =
        [NSMutableData dataWithCapacity:sizeof(record) + vertexLength + fragmentLength];
    [payload appendBytes:&record length:sizeof(record)];
    [payload appendBytes:vertexFunction length:vertexLength];
    [payload appendBytes:fragmentFunction length:fragmentLength];
    return AM12TraceRecordData(box, AM12_TRACE_CREATE_PIPELINE, payload);
}

uint32_t AM12CreateConstantBufferView(AM12Device *device, uint32_t slot, AM12Resource buffer)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box || box.commandBuffer || box.measuredFrames || slot >= AM12_MAX_DESCRIPTOR_SLOTS ||
        !AM12FindResource(box, buffer, AM12_RESOURCE_BUFFER))
        return 0;

    uint64_t modelGeneration = 0;
    if (![box.descriptorHeap writeResourceIdentifier:buffer
                                              atSlot:slot
                                          generation:&modelGeneration] ||
        modelGeneration > UINT32_MAX)
        return 0;
    uint32_t generation = (uint32_t)modelGeneration;
    AM12TraceCreateCBV record = {
        .slot = slot,
        .resource = buffer,
        .generation = generation,
    };
    if (!AM12TraceRecord(box, AM12_TRACE_CREATE_CBV, &record, sizeof(record)))
        return 0;
    return generation;
}

int AM12SetGraphicsRootDescriptorTable(AM12Device *device, uint32_t slot, uint32_t generation)
{
    AM12DeviceBox *box = AM12Box(device);
    AM12HeapDescriptorRecord descriptor = {0};
    AM12DescriptorTable table = {0};
    BOOL valid = box && box.commandBuffer && slot < AM12_MAX_DESCRIPTOR_SLOTS &&
                 [box.descriptorHeap descriptorAtSlot:slot record:&descriptor] &&
                 descriptor.generation == generation &&
                 [box.descriptorHeap materializeTableAtOffset:slot count:1 table:&table];
    if (!valid)
    {
        if (box)
            box.descriptorStaleRejects++;
        return AM12Failure("set root descriptor table", @"stale descriptor");
    }
    AM12ResourceEntry *entry =
        AM12FindResource(box, descriptor.resource_identifier, AM12_RESOURCE_BUFFER);
    id<MTLBuffer> modelBuffer =
        [box.descriptorHeap bufferForResourceIdentifier:descriptor.resource_identifier];
    id<MTLBuffer> tableBuffer = [box.descriptorHeap bufferForTable:table];
    uint64_t encodedAddress =
        tableBuffer.length >= sizeof(uint64_t) ? *(const uint64_t *)tableBuffer.contents : 0;
    if (!entry || !modelBuffer || modelBuffer != entry.buffer || !tableBuffer ||
        encodedAddress != modelBuffer.gpuAddress)
        return AM12Failure("set root descriptor table", @"descriptor resource mismatch");
    if (![box.descriptorHeap retainTable:table untilCommandBufferCompletes:box.commandBuffer])
        return AM12Failure("set root descriptor table", @"descriptor page retention");
    box.boundConstantBuffer = descriptor.resource_identifier;
    box.boundDescriptorPage = tableBuffer;
    AM12TraceRootTable record = {
        .slot = slot,
        .generation = generation,
    };
    return AM12TraceRecord(box, AM12_TRACE_SET_ROOT_TABLE, &record, sizeof(record));
}

int AM12BeginFrame(AM12Device *device, uint32_t frameIndex)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box || box.commandBuffer || frameIndex != box.measuredFrames ||
        frameIndex >= box.frameCount)
        return AM12Failure("begin frame", @"invalid frame state");
    if (box.setupEnd == 0.0)
        box.setupEnd = AM12NowMilliseconds();
    box.frameStart = AM12NowMilliseconds();
    box.encoderOrdinal = 0;
    box.clearReady = NO;
    box.drewThisFrame = NO;
    box.presentedThisFrame = NO;
    box.boundConstantBuffer = 0;
    box.boundDescriptorPage = nil;
    AM12BarrierTrackerResetAccesses(box.barrierTracker);
    memset(box->barrierAccessEncoders, 0, sizeof(box->barrierAccessEncoders));
    memset(box->barrierEncoderWaitMasks, 0, sizeof(box->barrierEncoderWaitMasks));
    memset(box->barrierEncoderSignaled, 0, sizeof(box->barrierEncoderSignaled));
    box.commandBuffer = [box.queue commandBuffer];
    if (!box.commandBuffer)
        return AM12Failure("begin frame", @"command buffer");
    if (box.layer)
    {
        box.drawable = [box.layer nextDrawable];
        if (!box.drawable)
        {
            box.commandBuffer = nil;
            return AM12Failure("begin frame", @"CAMetalLayer returned no drawable");
        }
    }
    AM12TraceFrame record = {.frame_index = frameIndex};
    return AM12TraceRecord(box, AM12_TRACE_BEGIN_FRAME, &record, sizeof(record));
}

int AM12TransitionResource(AM12Device *device, AM12Resource resource, AM12ResourceState before,
                           AM12ResourceState after)
{
    AM12DeviceBox *box = AM12Box(device);
    AM12ResourceEntry *entry = box.resources[@(resource)];
    uint32_t modelState = 0;
    if (!box || !box.commandBuffer || !entry || !AM12ResourceStateAllowed(entry.kind, before) ||
        !AM12ResourceStateAllowed(entry.kind, after) ||
        !AM12BarrierTrackerGetState(box.barrierTracker, resource, AM12_BARRIER_ALL_SUBRESOURCES,
                                    &modelState) ||
        modelState != before ||
        !AM12BarrierTrackerApplyTransition(box.barrierTracker, resource,
                                           AM12_BARRIER_ALL_SUBRESOURCES, before, after))
        return AM12Failure("transition resource", @"state mismatch");

    box.barrierTransitions++;
    AM12TraceTransition record = {
        .resource = resource,
        .before = before,
        .after = after,
    };
    return AM12TraceRecord(box, AM12_TRACE_TRANSITION, &record, sizeof(record));
}

int AM12ClearRenderTarget(AM12Device *device, AM12Resource target, const float color[4])
{
    AM12DeviceBox *box = AM12Box(device);
    AM12ResourceEntry *entry = AM12FindResource(box, target, AM12_RESOURCE_TEXTURE);
    if (!box || !box.commandBuffer || !entry ||
        !AM12ResourceHasState(box, target, AM12_RESOURCE_STATE_RENDER_TARGET) || !color ||
        !isfinite(color[0]) || !isfinite(color[1]) || !isfinite(color[2]) || !isfinite(color[3]))
        return AM12Failure("clear render target", @"invalid state");

    box.clearTarget = target;
    box.clearColor = MTLClearColorMake(color[0], color[1], color[2], color[3]);
    box.clearReady = YES;
    AM12TraceClear record = {
        .resource = target,
        .color = {color[0], color[1], color[2], color[3]},
    };
    return AM12TraceRecord(box, AM12_TRACE_CLEAR, &record, sizeof(record));
}

int AM12DrawInstanced(AM12Device *device, AM12Resource target, uint32_t vertexCount,
                      uint32_t instanceCount)
{
    AM12DeviceBox *box = AM12Box(device);
    AM12ResourceEntry *targetEntry = AM12FindResource(box, target, AM12_RESOURCE_TEXTURE);
    AM12ResourceEntry *constantEntry =
        AM12FindResource(box, box.boundConstantBuffer, AM12_RESOURCE_BUFFER);
    if (!box || !box.commandBuffer || !box.pipeline || !targetEntry || !constantEntry ||
        !box.boundDescriptorPage || !constantEntry.contentsDefined ||
        !AM12ResourceHasState(box, box.boundConstantBuffer, AM12_RESOURCE_STATE_CONSTANT_BUFFER) ||
        !AM12ResourceHasState(box, target, AM12_RESOURCE_STATE_RENDER_TARGET) || !box.clearReady ||
        box.clearTarget != target || vertexCount != 3 || instanceCount != 1)
        return AM12Failure("draw instanced", @"incomplete command state");

    const AM12BarrierAccess accesses[] = {
        {
            .queue = 0,
            .memory_object = box.boundConstantBuffer,
            .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
            .kind = AM12_BARRIER_ACCESS_READ,
        },
        {
            .queue = 0,
            .memory_object = target,
            .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
            .kind = AM12_BARRIER_ACCESS_WRITE,
        },
    };
    uint32_t barrierEncoder = 0;
    uint32_t barrierWaitMask = 0;
    if (!AM12PrepareBarrierEncoder(box, accesses, 2, &barrierEncoder, &barrierWaitMask))
        return AM12Failure("draw instanced", @"barrier plan or access capacity");

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = targetEntry.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = box.clearColor;
    id<MTLRenderCommandEncoder> encoder =
        [box.commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder)
        return AM12Failure("draw instanced", @"render encoder");
    for (uint32_t producer = 0; producer < barrierEncoder; producer++)
        if (barrierWaitMask & (UINT32_C(1) << producer))
            [encoder waitForFence:box.barrierFences[producer]
                     beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
    [encoder setRenderPipelineState:box.pipeline];
    [encoder setViewport:(MTLViewport){0.0, 0.0, box.width, box.height, 0.0, 1.0}];
    [encoder setVertexBuffer:box.boundDescriptorPage offset:0 atIndex:0];
    [encoder setFragmentBuffer:box.boundDescriptorPage offset:0 atIndex:0];
    [encoder useResource:constantEntry.buffer
                   usage:MTLResourceUsageRead
                  stages:MTLRenderStageVertex | MTLRenderStageFragment];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:vertexCount
              instanceCount:instanceCount];
    [encoder updateFence:box.barrierFences[barrierEncoder] afterStages:MTLRenderStageFragment];
    [encoder endEncoding];
    AM12CompleteBarrierEncoder(box, barrierEncoder, barrierWaitMask);
    targetEntry.contentsDefined = YES;
    box.clearReady = NO;
    box.drewThisFrame = YES;

    AM12TraceDraw record = {
        .resource = target,
        .vertex_count = vertexCount,
        .instance_count = instanceCount,
    };
    return AM12TraceRecord(box, AM12_TRACE_DRAW, &record, sizeof(record));
}

int AM12CopyTextureToBuffer(AM12Device *device, AM12Resource source, AM12Resource destination)
{
    AM12DeviceBox *box = AM12Box(device);
    AM12ImageLayout imageLayout;
    AM12ResourceEntry *sourceEntry = AM12FindResource(box, source, AM12_RESOURCE_TEXTURE);
    AM12ResourceEntry *destinationEntry = AM12FindResource(box, destination, AM12_RESOURCE_BUFFER);
    if (!box || !box.commandBuffer || !sourceEntry || !destinationEntry ||
        !AM12ComputeImageLayout(box.width, box.height, &imageLayout) ||
        !AM12ResourceHasState(box, source, AM12_RESOURCE_STATE_COPY_SOURCE) ||
        !AM12ResourceHasState(box, destination, AM12_RESOURCE_STATE_COPY_DESTINATION) ||
        !sourceEntry.contentsDefined || destinationEntry.buffer.length < imageLayout.rgbaBytes)
        return AM12Failure("copy texture to buffer", @"invalid state or size");
    NSUInteger rowPitch = imageLayout.rgbaRowBytes;

    BOOL deferToDrawable = box.drawable && box.measuredFrames + 1u == box.frameCount &&
                           box.pendingPresentationReadback == 0;
    if (deferToDrawable)
        box.pendingPresentationReadback = destination;
    else
    {
        const AM12BarrierAccess accesses[] = {
            {
                .queue = 0,
                .memory_object = source,
                .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
                .kind = AM12_BARRIER_ACCESS_READ,
            },
            {
                .queue = 0,
                .memory_object = destination,
                .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
                .kind = AM12_BARRIER_ACCESS_WRITE,
            },
        };
        uint32_t barrierEncoder = 0;
        uint32_t barrierWaitMask = 0;
        if (!AM12PrepareBarrierEncoder(box, accesses, 2, &barrierEncoder, &barrierWaitMask))
            return AM12Failure("copy texture to buffer", @"barrier plan or access capacity");
        id<MTLBlitCommandEncoder> encoder = [box.commandBuffer blitCommandEncoder];
        if (!encoder)
            return AM12Failure("copy texture to buffer", @"blit encoder");
        for (uint32_t producer = 0; producer < barrierEncoder; producer++)
            if (barrierWaitMask & (UINT32_C(1) << producer))
                [encoder waitForFence:box.barrierFences[producer]];
        [encoder copyFromTexture:sourceEntry.texture
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:(MTLOrigin){0, 0, 0}
                          sourceSize:(MTLSize){box.width, box.height, 1}
                            toBuffer:destinationEntry.buffer
                   destinationOffset:0
              destinationBytesPerRow:rowPitch
            destinationBytesPerImage:imageLayout.rgbaBytes];
        [encoder updateFence:box.barrierFences[barrierEncoder]];
        [encoder endEncoding];
        AM12CompleteBarrierEncoder(box, barrierEncoder, barrierWaitMask);
    }
    destinationEntry.contentsDefined = YES;

    AM12TraceCopy record = {
        .source = source,
        .destination = destination,
    };
    return AM12TraceRecord(box, AM12_TRACE_COPY, &record, sizeof(record));
}

int AM12Present(AM12Device *device, AM12Resource source)
{
    AM12DeviceBox *box = AM12Box(device);
    AM12ResourceEntry *entry = AM12FindResource(box, source, AM12_RESOURCE_TEXTURE);
    if (!box || !box.commandBuffer || !entry || box.presentedThisFrame ||
        (!AM12ResourceHasState(box, source, AM12_RESOURCE_STATE_RENDER_TARGET) &&
         !AM12ResourceHasState(box, source, AM12_RESOURCE_STATE_COPY_SOURCE)) ||
        !entry.contentsDefined)
        return AM12Failure("present", @"invalid source");

    if (box.drawable)
    {
        id<MTLTexture> destination = box.drawable.texture;
        if (destination.width != box.width || destination.height != box.height ||
            destination.pixelFormat != entry.texture.pixelFormat)
            return AM12Failure("present", @"drawable format or size mismatch");
        const AM12BarrierAccess presentAccesses[] = {
            {
                .queue = 0,
                .memory_object = source,
                .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
                .kind = AM12_BARRIER_ACCESS_READ,
            },
            {
                .queue = 0,
                .memory_object = AM12_RUNTIME_DRAWABLE_RESOURCE,
                .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
                .kind = AM12_BARRIER_ACCESS_WRITE,
            },
        };
        uint32_t presentBarrierEncoder = 0;
        uint32_t presentBarrierWaitMask = 0;
        if (!AM12PrepareBarrierEncoder(box, presentAccesses, 2, &presentBarrierEncoder,
                                       &presentBarrierWaitMask))
            return AM12Failure("present", @"barrier plan or access capacity");
        id<MTLBlitCommandEncoder> encoder = [box.commandBuffer blitCommandEncoder];
        if (!encoder)
            return AM12Failure("present", @"blit encoder");
        for (uint32_t producer = 0; producer < presentBarrierEncoder; producer++)
            if (presentBarrierWaitMask & (UINT32_C(1) << producer))
                [encoder waitForFence:box.barrierFences[producer]];
        [encoder copyFromTexture:entry.texture
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:(MTLOrigin){0, 0, 0}
                      sourceSize:(MTLSize){box.width, box.height, 1}
                       toTexture:destination
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:(MTLOrigin){0, 0, 0}];
        [encoder updateFence:box.barrierFences[presentBarrierEncoder]];
        [encoder endEncoding];
        AM12CompleteBarrierEncoder(box, presentBarrierEncoder, presentBarrierWaitMask);

        if (box.pendingPresentationReadback)
        {
            AM12ImageLayout imageLayout;
            AM12ResourceEntry *readback =
                AM12FindResource(box, box.pendingPresentationReadback, AM12_RESOURCE_BUFFER);
            if (!readback || !AM12ComputeImageLayout(box.width, box.height, &imageLayout) ||
                !AM12ResourceHasState(box, box.pendingPresentationReadback,
                                      AM12_RESOURCE_STATE_COPY_DESTINATION) ||
                readback.buffer.length < imageLayout.rgbaBytes)
                return AM12Failure("present", @"invalid drawable readback");
            const AM12BarrierAccess readbackAccesses[] = {
                {
                    .queue = 0,
                    .memory_object = AM12_RUNTIME_DRAWABLE_RESOURCE,
                    .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
                    .kind = AM12_BARRIER_ACCESS_READ,
                },
                {
                    .queue = 0,
                    .memory_object = box.pendingPresentationReadback,
                    .subresource = AM12_BARRIER_ALL_SUBRESOURCES,
                    .kind = AM12_BARRIER_ACCESS_WRITE,
                },
            };
            uint32_t readbackBarrierEncoder = 0;
            uint32_t readbackBarrierWaitMask = 0;
            if (!AM12PrepareBarrierEncoder(box, readbackAccesses, 2, &readbackBarrierEncoder,
                                           &readbackBarrierWaitMask))
                return AM12Failure("present", @"readback barrier plan or access capacity");
            id<MTLBlitCommandEncoder> readbackEncoder = [box.commandBuffer blitCommandEncoder];
            if (!readbackEncoder)
                return AM12Failure("present", @"readback blit encoder");
            for (uint32_t producer = 0; producer < readbackBarrierEncoder; producer++)
                if (readbackBarrierWaitMask & (UINT32_C(1) << producer))
                    [readbackEncoder waitForFence:box.barrierFences[producer]];
            [readbackEncoder copyFromTexture:destination
                                 sourceSlice:0
                                 sourceLevel:0
                                sourceOrigin:(MTLOrigin){0, 0, 0}
                                  sourceSize:(MTLSize){box.width, box.height, 1}
                                    toBuffer:readback.buffer
                           destinationOffset:0
                      destinationBytesPerRow:imageLayout.rgbaRowBytes
                    destinationBytesPerImage:imageLayout.rgbaBytes];
            [readbackEncoder updateFence:box.barrierFences[readbackBarrierEncoder]];
            [readbackEncoder endEncoding];
            AM12CompleteBarrierEncoder(box, readbackBarrierEncoder, readbackBarrierWaitMask);
            box.drawableReadbacks++;
            box.pendingPresentationReadback = 0;
        }
        if (box.measuredFrames + 1u == box.frameCount)
        {
            dispatch_semaphore_t signal = dispatch_semaphore_create(0);
            box.finalPresentationSignal = signal;
            [box.drawable addPresentedHandler:^(id<MTLDrawable> drawable) {
              (void)drawable;
              dispatch_semaphore_signal(signal);
            }];
        }
        [box.commandBuffer presentDrawable:box.drawable];
        box.presentedFrames++;
    }
    box.presentedThisFrame = YES;
    AM12TraceResourceOnly record = {.resource = source};
    return AM12TraceRecord(box, AM12_TRACE_PRESENT, &record, sizeof(record));
}

int AM12EndFrame(AM12Device *device)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box || !box.commandBuffer || box.measuredFrames >= box.frameCount || !box.drewThisFrame ||
        !box.presentedThisFrame)
        return AM12Failure("end frame", @"invalid frame state");
    if (box.pendingPresentationReadback)
        return AM12Failure("end frame", @"presentation readback was not encoded");

    AM12BarrierVerification barrierVerification = {0};
    uint32_t mappedBarrierEdges = 0;
    uint32_t unmetBarrierEdges = 0;
    if (!AM12VerifyBarrierSubmission(box, &barrierVerification, &mappedBarrierEdges,
                                     &unmetBarrierEdges))
        return AM12Failure("end frame", @"barrier plan verification");
    box.barrierEdgesRequired += box->barrierPlan.edge_count;
    box.barrierEdgesEmitted += mappedBarrierEdges;
    box.barrierEdgesUnmet += unmetBarrierEdges;
    if (barrierVerification.uncovered_hazard_count || unmetBarrierEdges)
        return AM12Failure("end frame", @"barrier plan was not emitted by encoders");

    if (!AM12TraceRecord(box, AM12_TRACE_END_FRAME, NULL, 0))
        return 0;

    [box.commandBuffer commit];
    [box.commandBuffer waitUntilCompleted];
    if (box.commandBuffer.error)
    {
        NSString *error = box.commandBuffer.error.localizedDescription;
        box.commandBuffer = nil;
        box.drawable = nil;
        return AM12Failure("execute frame", error);
    }
    if (box.finalPresentationSignal)
    {
        dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
        if (dispatch_semaphore_wait(box.finalPresentationSignal, deadline))
        {
            box.commandBuffer = nil;
            box.drawable = nil;
            box.finalPresentationSignal = nil;
            return AM12Failure("execute frame", @"final drawable was not presented");
        }
        box.finalPresentationSignal = nil;
    }
    box.frameTimes[box.measuredFrames++] = AM12NowMilliseconds() - box.frameStart;
    box.commandBuffer = nil;
    box.drawable = nil;
    return 1;
}

static int AM12CompareDouble(const void *left, const void *right)
{
    double a = *(const double *)left;
    double b = *(const double *)right;
    return a < b ? -1 : a > b ? 1 : 0;
}

int AM12FinishMetrics(AM12Device *device, AM12Metrics *metrics)
{
    AM12DeviceBox *box = AM12Box(device);
    if (!box || !metrics || !box.measuredFrames)
        return AM12Failure("finish metrics", @"no measured frames");

    AM12ResidencyBudget residencyBudget = [box.residencyManager budgetSnapshot];
    AM12ResidencyPlacementStats residencyStats = box.residencyManager.placementStats;
    AM12DescriptorHeapStatistics descriptorStats = box.descriptorHeap.statistics;
    AM12Metrics result = {
        .setup_ms = box.setupEnd - box.setupStart,
        .first_frame_ms = box.frameTimes[0],
        .image_digest = box.imageDigest,
        .changed_pixels = box.changedPixels,
        .residency_budget_bytes = residencyBudget.recommended_max_working_set_bytes,
        .residency_placed_bytes = residencyStats.cumulative_placed_bytes,
        .residency_placements = (uint32_t)residencyStats.placement_count,
        .descriptor_materializations =
            (uint32_t)(descriptorStats.cache_hits + descriptorStats.cache_misses),
        .descriptor_stale_rejects = box.descriptorStaleRejects,
        .barrier_transitions = box.barrierTransitions,
        .barrier_edges_required = box.barrierEdgesRequired,
        .barrier_edges_emitted = box.barrierEdgesEmitted,
        .barrier_edges_unmet = box.barrierEdgesUnmet,
        .presented_frames = box.presentedFrames,
        .drawable_readbacks = box.drawableReadbacks,
    };
    if (box.measuredFrames > 1)
    {
        uint32_t warmCount = box.measuredFrames - 1;
        double *sorted = malloc(warmCount * sizeof(*sorted));
        if (!sorted)
            return AM12Failure("finish metrics", @"allocation");
        memcpy(sorted, box.frameTimes + 1, warmCount * sizeof(*sorted));
        qsort(sorted, warmCount, sizeof(*sorted), AM12CompareDouble);
        for (uint32_t frame = 1; frame < box.measuredFrames; frame++)
            result.warm_mean_ms += box.frameTimes[frame];
        result.warm_mean_ms /= warmCount;
        result.warm_p50_ms = sorted[warmCount / 2];
        result.warm_p95_ms = sorted[(warmCount * 95u) / 100u];
        free(sorted);
    }
    *metrics = result;
    return 1;
}

int AM12WriteBitmapAndMeasure(AM12Device *device, AM12Resource readback, const char *path,
                              AM12Metrics *metrics)
{
    AM12DeviceBox *box = AM12Box(device);
    AM12ImageLayout imageLayout;
    AM12ResourceEntry *entry = AM12FindResource(box, readback, AM12_RESOURCE_BUFFER);
    if (!box || box.commandBuffer || box.measuredFrames != box.frameCount || !entry || !path ||
        !entry.contentsDefined || !AM12ComputeImageLayout(box.width, box.height, &imageLayout) ||
        entry.buffer.length < imageLayout.rgbaBytes)
        return AM12Failure("write bitmap", @"invalid arguments");

    AM12TraceResourceOnly outputRecord = {.resource = readback};
    if (!AM12TraceRecord(box, AM12_TRACE_OUTPUT, &outputRecord, sizeof(outputRecord)))
        return AM12Failure("write bitmap", @"trace output declaration");
    if (box.captureRequested)
        box.traceOutputRecorded = YES;

    FILE *file = fopen(path, "wb");
    if (!file)
        return AM12Failure("write bitmap", [NSString stringWithUTF8String:strerror(errno)]);
    uint32_t pixelOffset = 14u + 40u;
    uint32_t imageBytes = (uint32_t)imageLayout.bitmapImageBytes;
    uint8_t fileHeader[14] = {0};
    uint8_t infoHeader[40] = {0};
    fileHeader[0] = 'B';
    fileHeader[1] = 'M';
    memcpy(fileHeader + 2, &imageLayout.bitmapFileBytes, sizeof(uint32_t));
    memcpy(fileHeader + 10, &pixelOffset, sizeof(uint32_t));
    memcpy(infoHeader, &(uint32_t){40}, sizeof(uint32_t));
    uint32_t bitmapWidth = box.width;
    memcpy(infoHeader + 4, &bitmapWidth, sizeof(uint32_t));
    int32_t topDownHeight = -(int32_t)box.height;
    memcpy(infoHeader + 8, &topDownHeight, sizeof(int32_t));
    memcpy(infoHeader + 12, &(uint16_t){1}, sizeof(uint16_t));
    memcpy(infoHeader + 14, &(uint16_t){24}, sizeof(uint16_t));
    memcpy(infoHeader + 20, &imageBytes, sizeof(uint32_t));
    if (!AM12WriteAll(file, fileHeader, sizeof(fileHeader)) ||
        !AM12WriteAll(file, infoHeader, sizeof(infoHeader)))
    {
        fclose(file);
        return AM12Failure("write bitmap", @"header");
    }

    const uint8_t *pixels = entry.buffer.contents;
    const uint8_t *first = pixels;
    uint8_t *row = calloc(1, imageLayout.bitmapRowStride);
    uint64_t digest = AM12_FNV_OFFSET;
    size_t changed = 0;
    if (!row)
    {
        fclose(file);
        return AM12Failure("write bitmap", @"row allocation");
    }
    for (uint32_t y = 0; y < box.height; y++)
    {
        const uint8_t *source = pixels + (size_t)y * imageLayout.rgbaRowBytes;
        memset(row, 0, imageLayout.bitmapRowStride);
        for (uint32_t x = 0; x < box.width; x++)
        {
            const uint8_t *pixel = source + x * 4u;
            row[x * 3u + 0] = pixel[2];
            row[x * 3u + 1] = pixel[1];
            row[x * 3u + 2] = pixel[0];
            if (pixel[0] != first[0] || pixel[1] != first[1] || pixel[2] != first[2])
                changed++;
            for (uint32_t channel = 0; channel < 3; channel++)
            {
                digest ^= pixel[channel];
                digest *= AM12_FNV_PRIME;
            }
        }
        if (!AM12WriteAll(file, row, imageLayout.bitmapRowStride))
        {
            free(row);
            fclose(file);
            return AM12Failure("write bitmap", @"pixels");
        }
    }
    free(row);
    if (fclose(file))
        return AM12Failure("write bitmap", @"close");

    box.imageDigest = digest;
    box.changedPixels = changed;
    return AM12FinishMetrics(device, metrics);
}

typedef struct AM12TraceView
{
    const uint8_t *bytes;
    size_t size;
    size_t offset;
} AM12TraceView;

static BOOL AM12TraceRead(AM12TraceView *view, void *output, size_t size)
{
    if (view->offset > view->size || size > view->size - view->offset)
        return NO;
    if (output)
        memcpy(output, view->bytes + view->offset, size);
    view->offset += size;
    return YES;
}

static BOOL AM12TraceNext(AM12TraceView *view, AM12TraceRecordHeader *header,
                          const uint8_t **payload)
{
    if (view->offset == view->size)
        return NO;
    if (!AM12TraceRead(view, header, sizeof(*header)) || header->flags != 0 ||
        header->payload_size > view->size - view->offset)
    {
        view->offset = SIZE_MAX;
        return NO;
    }
    *payload = view->bytes + view->offset;
    view->offset += header->payload_size;
    return YES;
}

static BOOL AM12PayloadFixed(const AM12TraceRecordHeader *header, size_t expected)
{
    return header->payload_size == expected;
}

typedef struct AM12TraceResourceValidation
{
    BOOL live;
    AM12ResourceKind kind;
    uint64_t size;
    AM12ResourceState state;
    BOOL contentsDefined;
} AM12TraceResourceValidation;

typedef struct AM12TraceDescriptorValidation
{
    BOOL live;
    AM12Resource resource;
    uint32_t generation;
} AM12TraceDescriptorValidation;

struct AM12TracePlan
{
    AM12TraceDevice device;
    size_t metallibOffset;
    size_t metallibSize;
    AM12Resource output;
};

static BOOL AM12RejectTrace(NSString **detail, NSString *message)
{
    if (detail)
        *detail = message;
    return NO;
}

static BOOL AM12TraceReserveBarrierAccesses(uint32_t *accessCount, uint32_t addition)
{
    if (!accessCount || addition > AM12_RUNTIME_BARRIER_ACCESSES - *accessCount)
        return NO;
    *accessCount += addition;
    return YES;
}

static BOOL AM12TraceResourceIsLive(const AM12TraceResourceValidation *resources,
                                    AM12Resource resource)
{
    return resource > 0 && resource < AM12_MAX_RESOURCES && resources[resource].live;
}

static BOOL AM12PreflightTrace(NSData *traceData, AM12TracePlan *plan, NSString **detail)
{
    if (!traceData || traceData.length < sizeof(AM12TraceHeader) ||
        traceData.length > AM12_MAX_TRACE_BYTES)
        return AM12RejectTrace(detail, @"trace size is outside the supported bounds");

    const uint8_t *bytes = traceData.bytes;
    AM12TraceHeader header;
    memcpy(&header, bytes, sizeof(header));
    if (memcmp(header.magic, "AM12TRC1", 8) || header.major != AM12_TRACE_FORMAT_MAJOR ||
        header.minor != AM12_TRACE_FORMAT_MINOR || header.header_size != sizeof(header) ||
        header.byte_order != UINT32_C(0x01020304))
        return AM12RejectTrace(detail, @"unsupported trace header or version");

    AM12TraceResourceValidation resources[AM12_MAX_RESOURCES] = {0};
    AM12TraceDescriptorValidation descriptors[AM12_MAX_DESCRIPTOR_SLOTS] = {0};
    AM12TraceView view = {
        .bytes = bytes,
        .size = traceData.length,
        .offset = sizeof(header),
    };
    AM12TracePlan result = {0};
    AM12ImageLayout imageLayout = {0};
    AM12TraceRecordHeader recordHeader;
    const uint8_t *payload = NULL;
    uint32_t recordCount = 0;
    uint32_t nextResource = 1;
    uint32_t descriptorGeneration = 0;
    uint32_t completedFrames = 0;
    uint32_t frameBarrierAccessCount = 0;
    uint64_t placedTextureBytes = 0;
    uint64_t sharedBufferBytes = 0;
    BOOL sawDevice = NO;
    BOOL sawMetallib = NO;
    BOOL sawPipeline = NO;
    BOOL sawAnyFrame = NO;
    BOOL frameActive = NO;
    BOOL rootBound = NO;
    BOOL clearReady = NO;
    BOOL drew = NO;
    BOOL presented = NO;
    BOOL sawOutput = NO;
    AM12Resource clearTarget = 0;
    AM12Resource boundConstantBuffer = 0;

    while (AM12TraceNext(&view, &recordHeader, &payload))
    {
        if (++recordCount > AM12_MAX_TRACE_RECORDS)
            return AM12RejectTrace(detail, @"trace contains too many records");
        if (sawOutput)
            return AM12RejectTrace(detail, @"output declaration must be the final record");

        switch ((AM12TraceOpcode)recordHeader.opcode)
        {
        case AM12_TRACE_DEVICE:
        {
            AM12TraceDevice record;
            if (recordCount != 1 || sawDevice || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail,
                                       @"device record is missing, duplicate, or unordered");
            memcpy(&record, payload, sizeof(record));
            if (record.frame_count == 0 || record.frame_count > AM12_MAX_FRAMES ||
                !AM12ComputeImageLayout(record.width, record.height, &imageLayout))
                return AM12RejectTrace(detail, @"device dimensions or frame count exceed bounds");
            result.device = record;
            sawDevice = YES;
            break;
        }
        case AM12_TRACE_METALLIB:
            if (recordCount != 2 || !sawDevice || sawMetallib || !recordHeader.payload_size ||
                recordHeader.payload_size > AM12_MAX_METALLIB_BYTES)
                return AM12RejectTrace(
                    detail, @"metallib record is missing, duplicate, unordered, or large");
            result.metallibOffset = (size_t)(payload - bytes);
            result.metallibSize = recordHeader.payload_size;
            sawMetallib = YES;
            break;
        case AM12_TRACE_CREATE_TEXTURE:
        case AM12_TRACE_CREATE_BUFFER:
        {
            AM12TraceCreateResource record;
            if (!sawMetallib || sawAnyFrame || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"resource creation is malformed or out of order");
            memcpy(&record, payload, sizeof(record));
            if (record.resource != nextResource || record.resource >= AM12_MAX_RESOURCES ||
                !record.size)
                return AM12RejectTrace(detail, @"resource identifiers must be canonical");
            AM12TraceResourceValidation *resource = &resources[record.resource];
            resource->live = YES;
            resource->size = record.size;
            resource->state = AM12_RESOURCE_STATE_UNDEFINED;
            if (recordHeader.opcode == AM12_TRACE_CREATE_TEXTURE)
            {
                if (record.size > AM12_HEAP_BYTES ||
                    placedTextureBytes > AM12_HEAP_BYTES - record.size)
                    return AM12RejectTrace(detail, @"placed texture exceeds the residency heap");
                placedTextureBytes += record.size;
                resource->kind = AM12_RESOURCE_TEXTURE;
            }
            else
            {
                if (record.size > AM12_MAX_BUFFER_BYTES || record.size > SIZE_MAX ||
                    sharedBufferBytes > AM12_MAX_BUFFER_BYTES - record.size)
                    return AM12RejectTrace(detail, @"buffer exceeds the supported size bound");
                sharedBufferBytes += record.size;
                resource->kind = AM12_RESOURCE_BUFFER;
                resource->contentsDefined = YES;
            }
            nextResource++;
            break;
        }
        case AM12_TRACE_WRITE_RESOURCE:
        {
            AM12TraceWriteResource record;
            if (!sawMetallib || recordHeader.payload_size < sizeof(record))
                return AM12RejectTrace(detail, @"resource write payload is malformed");
            memcpy(&record, payload, sizeof(record));
            size_t contentSize = recordHeader.payload_size - sizeof(record);
            if (!AM12TraceResourceIsLive(resources, record.resource) ||
                resources[record.resource].kind != AM12_RESOURCE_BUFFER ||
                record.size != contentSize || !record.size ||
                record.offset > resources[record.resource].size ||
                record.size > resources[record.resource].size - record.offset)
                return AM12RejectTrace(detail, @"resource write has an invalid buffer range");
            resources[record.resource].contentsDefined = YES;
            break;
        }
        case AM12_TRACE_CREATE_PIPELINE:
        {
            AM12TracePipeline record;
            if (!sawMetallib || sawAnyFrame || sawPipeline ||
                recordHeader.payload_size < sizeof(record))
                return AM12RejectTrace(detail, @"pipeline record is duplicate, malformed, or late");
            memcpy(&record, payload, sizeof(record));
            size_t namesSize = 0;
            if (!record.vertex_length || !record.fragment_length ||
                record.vertex_length > AM12_MAX_ENTRY_NAME_BYTES ||
                record.fragment_length > AM12_MAX_ENTRY_NAME_BYTES ||
                !AM12CheckedAddSize(record.vertex_length, record.fragment_length, &namesSize) ||
                namesSize != recordHeader.payload_size - sizeof(record))
                return AM12RejectTrace(detail, @"pipeline entry-name lengths are invalid");
            const uint8_t *vertex = payload + sizeof(record);
            const uint8_t *fragment = vertex + record.vertex_length;
            if (memchr(vertex, 0, record.vertex_length) ||
                memchr(fragment, 0, record.fragment_length) ||
                ![[NSString alloc] initWithBytes:vertex
                                          length:record.vertex_length
                                        encoding:NSUTF8StringEncoding] ||
                ![[NSString alloc] initWithBytes:fragment
                                          length:record.fragment_length
                                        encoding:NSUTF8StringEncoding])
                return AM12RejectTrace(detail, @"pipeline entry names are not canonical UTF-8");
            sawPipeline = YES;
            break;
        }
        case AM12_TRACE_CREATE_CBV:
        {
            AM12TraceCreateCBV record;
            if (!sawMetallib || sawAnyFrame || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"CBV record is malformed or late");
            memcpy(&record, payload, sizeof(record));
            if (record.slot >= AM12_MAX_DESCRIPTOR_SLOTS ||
                !AM12TraceResourceIsLive(resources, record.resource) ||
                resources[record.resource].kind != AM12_RESOURCE_BUFFER ||
                record.generation != descriptorGeneration + 1u)
                return AM12RejectTrace(detail, @"CBV slot, resource, or generation is invalid");
            descriptorGeneration = record.generation;
            descriptors[record.slot] = (AM12TraceDescriptorValidation){
                .live = YES,
                .resource = record.resource,
                .generation = record.generation,
            };
            break;
        }
        case AM12_TRACE_SET_ROOT_TABLE:
        {
            AM12TraceRootTable record;
            if (!sawMetallib || !frameActive || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"root-table record is malformed");
            memcpy(&record, payload, sizeof(record));
            if (record.slot >= AM12_MAX_DESCRIPTOR_SLOTS || !descriptors[record.slot].live ||
                descriptors[record.slot].generation != record.generation)
                return AM12RejectTrace(detail, @"root-table descriptor generation is stale");
            rootBound = YES;
            boundConstantBuffer = descriptors[record.slot].resource;
            break;
        }
        case AM12_TRACE_BEGIN_FRAME:
        {
            AM12TraceFrame record;
            if (!sawMetallib || !sawPipeline || frameActive ||
                !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"frame begin is malformed or nested");
            memcpy(&record, payload, sizeof(record));
            if (record.frame_index != completedFrames ||
                record.frame_index >= result.device.frame_count)
                return AM12RejectTrace(detail, @"frame indices must be contiguous and bounded");
            sawAnyFrame = YES;
            frameActive = YES;
            frameBarrierAccessCount = 0;
            rootBound = NO;
            boundConstantBuffer = 0;
            clearReady = NO;
            drew = NO;
            presented = NO;
            break;
        }
        case AM12_TRACE_TRANSITION:
        {
            AM12TraceTransition record;
            if (!frameActive || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"transition is malformed or outside a frame");
            memcpy(&record, payload, sizeof(record));
            if (!AM12TraceResourceIsLive(resources, record.resource))
                return AM12RejectTrace(detail, @"transition references an unknown resource");
            AM12TraceResourceValidation *resource = &resources[record.resource];
            if (!AM12ResourceStateAllowed(resource->kind, record.before) ||
                !AM12ResourceStateAllowed(resource->kind, record.after) ||
                resource->state != (AM12ResourceState)record.before)
                return AM12RejectTrace(detail, @"transition state or before-state is invalid");
            resource->state = (AM12ResourceState)record.after;
            break;
        }
        case AM12_TRACE_CLEAR:
        {
            AM12TraceClear record;
            if (!frameActive || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"clear is malformed or outside a frame");
            memcpy(&record, payload, sizeof(record));
            if (!AM12TraceResourceIsLive(resources, record.resource) ||
                resources[record.resource].kind != AM12_RESOURCE_TEXTURE ||
                resources[record.resource].state != AM12_RESOURCE_STATE_RENDER_TARGET ||
                !isfinite(record.color[0]) || !isfinite(record.color[1]) ||
                !isfinite(record.color[2]) || !isfinite(record.color[3]))
                return AM12RejectTrace(detail, @"clear target, state, or color is invalid");
            clearTarget = record.resource;
            clearReady = YES;
            break;
        }
        case AM12_TRACE_DRAW:
        {
            AM12TraceDraw record;
            if (!frameActive || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"draw is malformed or outside a frame");
            memcpy(&record, payload, sizeof(record));
            if (!sawPipeline || !rootBound ||
                !AM12TraceResourceIsLive(resources, boundConstantBuffer) ||
                resources[boundConstantBuffer].state != AM12_RESOURCE_STATE_CONSTANT_BUFFER ||
                !resources[boundConstantBuffer].contentsDefined || !clearReady ||
                record.resource != clearTarget ||
                !AM12TraceResourceIsLive(resources, record.resource) ||
                resources[record.resource].kind != AM12_RESOURCE_TEXTURE ||
                resources[record.resource].state != AM12_RESOURCE_STATE_RENDER_TARGET ||
                record.vertex_count != 3 || record.instance_count != 1 ||
                !AM12TraceReserveBarrierAccesses(&frameBarrierAccessCount, 2))
                return AM12RejectTrace(detail, @"draw command state is incomplete");
            resources[record.resource].contentsDefined = YES;
            clearReady = NO;
            drew = YES;
            break;
        }
        case AM12_TRACE_COPY:
        {
            AM12TraceCopy record;
            if (!frameActive || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"copy is malformed or outside a frame");
            memcpy(&record, payload, sizeof(record));
            if (!AM12TraceResourceIsLive(resources, record.source) ||
                !AM12TraceResourceIsLive(resources, record.destination) ||
                resources[record.source].kind != AM12_RESOURCE_TEXTURE ||
                resources[record.destination].kind != AM12_RESOURCE_BUFFER ||
                resources[record.source].state != AM12_RESOURCE_STATE_COPY_SOURCE ||
                resources[record.destination].state != AM12_RESOURCE_STATE_COPY_DESTINATION ||
                !resources[record.source].contentsDefined ||
                resources[record.destination].size < imageLayout.rgbaBytes ||
                !AM12TraceReserveBarrierAccesses(&frameBarrierAccessCount, 2))
                return AM12RejectTrace(detail, @"copy resources, states, or size are invalid");
            resources[record.destination].contentsDefined = YES;
            break;
        }
        case AM12_TRACE_PRESENT:
        {
            AM12TraceResourceOnly record;
            if (!frameActive || presented || !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"present is malformed or duplicated");
            memcpy(&record, payload, sizeof(record));
            if (!AM12TraceResourceIsLive(resources, record.resource) ||
                resources[record.resource].kind != AM12_RESOURCE_TEXTURE ||
                (resources[record.resource].state != AM12_RESOURCE_STATE_RENDER_TARGET &&
                 resources[record.resource].state != AM12_RESOURCE_STATE_COPY_SOURCE) ||
                !resources[record.resource].contentsDefined ||
                !AM12TraceReserveBarrierAccesses(&frameBarrierAccessCount, 2))
                return AM12RejectTrace(detail, @"present source or state is invalid");
            presented = YES;
            break;
        }
        case AM12_TRACE_END_FRAME:
            if (!frameActive || !drew || !presented || !AM12PayloadFixed(&recordHeader, 0))
                return AM12RejectTrace(detail, @"frame end is malformed or incomplete");
            frameActive = NO;
            completedFrames++;
            break;
        case AM12_TRACE_OUTPUT:
        {
            AM12TraceResourceOnly record;
            if (frameActive || completedFrames != result.device.frame_count ||
                !AM12PayloadFixed(&recordHeader, sizeof(record)))
                return AM12RejectTrace(detail, @"output declaration is malformed or early");
            memcpy(&record, payload, sizeof(record));
            if (!AM12TraceResourceIsLive(resources, record.resource) ||
                resources[record.resource].kind != AM12_RESOURCE_BUFFER ||
                resources[record.resource].size < imageLayout.rgbaBytes ||
                !resources[record.resource].contentsDefined)
                return AM12RejectTrace(detail, @"output buffer is missing, small, or undefined");
            result.output = record.resource;
            sawOutput = YES;
            break;
        }
        default:
            return AM12RejectTrace(detail, @"trace contains an unknown opcode");
        }
    }

    if (view.offset == SIZE_MAX)
        return AM12RejectTrace(detail, @"trace record flags, size, or tail are invalid");
    if (!sawDevice || !sawMetallib || !sawPipeline || !sawOutput || frameActive ||
        completedFrames != result.device.frame_count)
        return AM12RejectTrace(detail, @"trace is missing required canonical records");
    if (plan)
        *plan = result;
    return YES;
}

static int AM12ReplaySingle(NSData *traceData, const AM12TracePlan *plan, const char *bitmapPath,
                            AM12MetalLayerRef presentationLayer, double replaySetupStart,
                            AM12Metrics *metrics)
{
    double replaySetupMilliseconds = 0.0;
    const uint8_t *bytes = traceData.bytes;
    AM12TraceHeader header;
    memcpy(&header, bytes, sizeof(header));
    NSData *metallib =
        [traceData subdataWithRange:NSMakeRange(plan->metallibOffset, plan->metallibSize)];
    AM12TraceRecordHeader recordHeader;
    const uint8_t *payload = NULL;

    NSString *temporaryPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"alloy-metal12-%@.metallib",
                                                                  NSUUID.UUID.UUIDString]];
    if (![metallib writeToFile:temporaryPath atomically:YES])
        return AM12Failure("replay", @"temporary metallib");
    AM12DeviceDescriptor descriptor = {
        .width = plan->device.width,
        .height = plan->device.height,
        .frame_count = plan->device.frame_count,
        .metallib_path = temporaryPath.fileSystemRepresentation,
        .capture_path = NULL,
        .presentation_layer = presentationLayer,
    };
    AM12Device *device = AM12CreateDevice(&descriptor);
    [[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
    if (!device)
        return 0;

    int ok = 1;
    AM12Resource output = 0;
    AM12TraceView view = {
        .bytes = bytes,
        .size = traceData.length,
        .offset = sizeof(header),
    };
    while (ok && AM12TraceNext(&view, &recordHeader, &payload))
    {
        switch ((AM12TraceOpcode)recordHeader.opcode)
        {
        case AM12_TRACE_DEVICE:
        case AM12_TRACE_METALLIB:
            break;
        case AM12_TRACE_CREATE_TEXTURE:
        {
            AM12TraceCreateResource record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12CreateRenderTarget(device) == record.resource;
            }
            break;
        }
        case AM12_TRACE_CREATE_BUFFER:
        {
            AM12TraceCreateResource record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = record.size <= SIZE_MAX &&
                     AM12CreateSharedBuffer(device, (size_t)record.size) == record.resource;
            }
            break;
        }
        case AM12_TRACE_WRITE_RESOURCE:
        {
            AM12TraceWriteResource record;
            ok = recordHeader.payload_size >= sizeof(record);
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                size_t contentSize = recordHeader.payload_size - sizeof(record);
                ok = record.size == contentSize && record.offset <= SIZE_MAX &&
                     AM12WriteResource(device, record.resource, (size_t)record.offset,
                                       payload + sizeof(record), contentSize);
            }
            break;
        }
        case AM12_TRACE_CREATE_PIPELINE:
        {
            AM12TracePipeline record;
            ok = recordHeader.payload_size >= sizeof(record);
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                size_t namesSize = (size_t)record.vertex_length + record.fragment_length;
                ok = namesSize == recordHeader.payload_size - sizeof(record);
                if (ok)
                {
                    char *vertex = calloc(record.vertex_length + 1u, 1);
                    char *fragment = calloc(record.fragment_length + 1u, 1);
                    ok = vertex && fragment;
                    if (ok)
                    {
                        memcpy(vertex, payload + sizeof(record), record.vertex_length);
                        memcpy(fragment, payload + sizeof(record) + record.vertex_length,
                               record.fragment_length);
                        ok = AM12CreateGraphicsPipeline(device, vertex, fragment);
                    }
                    free(vertex);
                    free(fragment);
                }
            }
            break;
        }
        case AM12_TRACE_CREATE_CBV:
        {
            AM12TraceCreateCBV record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12CreateConstantBufferView(device, record.slot, record.resource) ==
                     record.generation;
            }
            break;
        }
        case AM12_TRACE_SET_ROOT_TABLE:
        {
            AM12TraceRootTable record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12SetGraphicsRootDescriptorTable(device, record.slot, record.generation);
            }
            break;
        }
        case AM12_TRACE_BEGIN_FRAME:
        {
            AM12TraceFrame record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                if (replaySetupMilliseconds == 0.0)
                    replaySetupMilliseconds = AM12NowMilliseconds() - replaySetupStart;
                ok = AM12BeginFrame(device, record.frame_index);
            }
            break;
        }
        case AM12_TRACE_TRANSITION:
        {
            AM12TraceTransition record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12TransitionResource(device, record.resource, record.before, record.after);
            }
            break;
        }
        case AM12_TRACE_CLEAR:
        {
            AM12TraceClear record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12ClearRenderTarget(device, record.resource, record.color);
            }
            break;
        }
        case AM12_TRACE_DRAW:
        {
            AM12TraceDraw record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12DrawInstanced(device, record.resource, record.vertex_count,
                                       record.instance_count);
            }
            break;
        }
        case AM12_TRACE_COPY:
        {
            AM12TraceCopy record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12CopyTextureToBuffer(device, record.source, record.destination);
            }
            break;
        }
        case AM12_TRACE_PRESENT:
        {
            AM12TraceResourceOnly record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                ok = AM12Present(device, record.resource);
            }
            break;
        }
        case AM12_TRACE_END_FRAME:
            ok = AM12PayloadFixed(&recordHeader, 0) && AM12EndFrame(device);
            break;
        case AM12_TRACE_OUTPUT:
        {
            AM12TraceResourceOnly record;
            ok = AM12PayloadFixed(&recordHeader, sizeof(record));
            if (ok)
            {
                memcpy(&record, payload, sizeof(record));
                output = record.resource;
            }
            break;
        }
        default:
            ok = AM12Failure("replay", @"unknown trace opcode");
            break;
        }
    }
    if (view.offset == SIZE_MAX)
        ok = AM12Failure("replay", @"truncated record");
    if (ok && !output)
        ok = AM12Failure("replay", @"missing output declaration");
    if (ok && output != plan->output)
        ok = AM12Failure("replay", @"output declaration changed after preflight");
    if (ok)
        ok = AM12WriteBitmapAndMeasure(device, output, bitmapPath, metrics);
    if (ok)
        metrics->setup_ms = replaySetupMilliseconds;
    AM12DestroyDevice(device);
    return ok;
}

int AM12ValidateTrace(const char *tracePath)
{
    @autoreleasepool
    {
        if (!tracePath)
            return AM12Failure("validate trace", @"invalid path");
        NSString *detail = nil;
        NSData *trace = AM12ReadBoundedFile(tracePath, AM12_MAX_TRACE_BYTES, &detail);
        if (!trace)
            return AM12Failure("validate trace", detail);
        AM12TracePlan plan;
        if (!AM12PreflightTrace(trace, &plan, &detail))
            return AM12Failure("validate trace", detail);
        return 1;
    }
}

int AM12ReplayTrace(const char *tracePath, const char *bitmapPath,
                    AM12MetalLayerRef presentationLayer, uint32_t repeatCount,
                    AM12ReplaySummary *summary)
{
    @autoreleasepool
    {
        if (!tracePath || !bitmapPath || !repeatCount || repeatCount > AM12_MAX_FRAMES || !summary)
            return AM12Failure("replay", @"invalid arguments");
        NSString *detail = nil;
        NSData *trace = AM12ReadBoundedFile(tracePath, AM12_MAX_TRACE_BYTES, &detail);
        if (!trace)
            return AM12Failure("replay", detail);

        AM12ReplaySummary result = {.runs = repeatCount};
        uint64_t expectedDigest = 0;
        for (uint32_t run = 0; run < repeatCount; run++)
        {
            double replaySetupStart = AM12NowMilliseconds();
            AM12TracePlan plan;
            if (!AM12PreflightTrace(trace, &plan, &detail))
                return AM12Failure("replay preflight", detail);
            AM12Metrics metrics = {0};
            if (!AM12ReplaySingle(trace, &plan, bitmapPath, presentationLayer, replaySetupStart,
                                  &metrics))
                return 0;
            if (!run)
                expectedDigest = metrics.image_digest;
            if (metrics.image_digest != expectedDigest)
                return AM12Failure("replay", @"digest instability");
            result.mean_timings.setup_ms += metrics.setup_ms;
            result.mean_timings.first_frame_ms += metrics.first_frame_ms;
            result.mean_timings.warm_mean_ms += metrics.warm_mean_ms;
            result.mean_timings.warm_p50_ms += metrics.warm_p50_ms;
            result.mean_timings.warm_p95_ms += metrics.warm_p95_ms;
            result.stable_runs++;
            result.last_run = metrics;
        }
        result.mean_timings.setup_ms /= repeatCount;
        result.mean_timings.first_frame_ms /= repeatCount;
        result.mean_timings.warm_mean_ms /= repeatCount;
        result.mean_timings.warm_p50_ms /= repeatCount;
        result.mean_timings.warm_p95_ms /= repeatCount;
        result.image_digest = expectedDigest;
        *summary = result;
        return 1;
    }
}
