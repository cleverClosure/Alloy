/*
 * Internal Metal12 unified-memory residency manager.
 * Author: Timur Isaev
 */

#import "AM12ResidencyManager.h"

#include <limits.h>

NSString *const AM12ResidencyErrorDomain = @"org.alloy.metal12.residency";

static uint64_t AM12SaturatingAdd(uint64_t left, uint64_t right)
{
    return UINT64_MAX - left < right ? UINT64_MAX : left + right;
}

static NSError *AM12ResidencyError(AM12ResidencyErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:AM12ResidencyErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

static void AM12SetResidencyError(NSError **error, AM12ResidencyErrorCode code,
                                  NSString *description)
{
    if (error)
        *error = AM12ResidencyError(code, description);
}

@class AM12ResidencyManager;

@interface AM12ResidencyLease ()

@property(nonatomic, strong, readwrite) id<MTLResource> resource;
@property(nonatomic, weak) AM12ResidencyManager *manager;
@property(nonatomic, readwrite, getter=isPlaced) BOOL placed;
@property(nonatomic, readwrite, getter=isRetired) BOOL retired;
@property(nonatomic, readwrite) NSUInteger heapOffset;
@property(nonatomic, readwrite) NSUInteger heapLength;
@property(nonatomic, readwrite) uint64_t generation;

- (instancetype)initWithResource:(id<MTLResource>)resource
                         manager:(AM12ResidencyManager *)manager
                          placed:(BOOL)placed
                          offset:(NSUInteger)offset
                          length:(NSUInteger)length
                      generation:(uint64_t)generation;

@end

@implementation AM12ResidencyLease

- (instancetype)initWithResource:(id<MTLResource>)resource
                         manager:(AM12ResidencyManager *)manager
                          placed:(BOOL)placed
                          offset:(NSUInteger)offset
                          length:(NSUInteger)length
                      generation:(uint64_t)generation
{
    self = [super init];
    if (self)
    {
        _resource = resource;
        _manager = manager;
        _placed = placed;
        _heapOffset = offset;
        _heapLength = length;
        _generation = generation;
    }
    return self;
}

@end

@interface AM12ResidencyCacheExpectation : NSObject

@property(nonatomic) NSUInteger length;
@property(nonatomic) MTLResourceOptions options;
@property(nonatomic) uint64_t checksum;

@end

@implementation AM12ResidencyCacheExpectation
@end

@interface AM12ResidencyCacheEntry : NSObject

@property(nonatomic) uint32_t key;
@property(nonatomic) NSUInteger length;
@property(nonatomic) MTLResourceOptions options;
@property(nonatomic, strong) id<MTLBuffer> buffer;

@end

@implementation AM12ResidencyCacheEntry
@end

@interface AM12ResidencyManager ()

@property(nonatomic, strong, readwrite) id<MTLDevice> device;
@property(nonatomic, readwrite) NSUInteger cacheCapacity;
@property(nonatomic, readwrite) AM12ResidencyPressurePolicy pressurePolicy;
@property(nonatomic, strong, nullable) id<MTLHeap> placementHeap;
@property(nonatomic) NSUInteger placementHeapSize;
@property(nonatomic, strong) NSMutableArray<AM12ResidencyLease *> *activePlacements;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, AM12ResidencyCacheExpectation *> *cacheExpectations;
@property(nonatomic, strong) NSMutableArray<AM12ResidencyCacheEntry *> *residentCache;
@property(nonatomic, strong) NSMutableArray<id<MTLBuffer>> *pressureBuffers;
@property(nonatomic) uint64_t nextGeneration;
@property(nonatomic) uint64_t activePlacedBytes;
@property(nonatomic) uint64_t cumulativePlacedBytes;
@property(nonatomic) uint64_t placementCount;
@property(nonatomic) uint64_t aliasRetirementCount;
@property(nonatomic) uint64_t cacheEvictionCount;
@property(nonatomic) uint64_t cacheRematerializationCount;
@property(nonatomic) uint64_t cacheMismatchCount;
@property(nonatomic) uint64_t pressureAllocationFailureCount;
@property(nonatomic) uint64_t pressureEvictRetryRecoveryCount;
@property(nonatomic) uint64_t pressureSuccessfulAllocationBytes;

@end

@implementation AM12ResidencyManager

- (instancetype)initWithDevice:(id<MTLDevice>)device
                 cacheCapacity:(NSUInteger)cacheCapacity
                pressurePolicy:(AM12ResidencyPressurePolicy)pressurePolicy
{
    self = [super init];
    if (self)
    {
        _device = device;
        _cacheCapacity = cacheCapacity;
        _pressurePolicy = pressurePolicy;
        _activePlacements = [NSMutableArray array];
        _cacheExpectations = [NSMutableDictionary dictionary];
        _residentCache = [NSMutableArray array];
        _pressureBuffers = [NSMutableArray array];
        _nextGeneration = 1;
    }
    return self;
}

- (AM12ResidencyBudget)budgetSnapshot
{
    uint64_t recommended = self.device.recommendedMaxWorkingSetSize;
    uint64_t allocated = self.device.currentAllocatedSize;
    return (AM12ResidencyBudget){
        .recommended_max_working_set_bytes = recommended,
        .current_allocated_bytes = allocated,
        .available_for_reservation_bytes = recommended > allocated ? recommended - allocated : 0,
    };
}

- (uint64_t)pressureTargetBytes
{
    return AM12SaturatingAdd(self.device.recommendedMaxWorkingSetSize,
                             self.pressurePolicy.oversubscription_margin_bytes);
}

- (AM12ResidencyPlacementStats)placementStats
{
    return (AM12ResidencyPlacementStats){
        .active_placed_bytes = self.activePlacedBytes,
        .cumulative_placed_bytes = self.cumulativePlacedBytes,
        .placement_count = self.placementCount,
        .alias_retirement_count = self.aliasRetirementCount,
    };
}

- (AM12ResidencyCacheStats)cacheStats
{
    return (AM12ResidencyCacheStats){
        .eviction_count = self.cacheEvictionCount,
        .rematerialization_count = self.cacheRematerializationCount,
        .mismatch_count = self.cacheMismatchCount,
        .resident_count = self.residentCache.count,
    };
}

- (AM12ResidencyPressureStats)pressureStats
{
    return (AM12ResidencyPressureStats){
        .allocation_failure_count = self.pressureAllocationFailureCount,
        .evict_retry_recovery_count = self.pressureEvictRetryRecoveryCount,
        .successful_allocation_bytes = self.pressureSuccessfulAllocationBytes,
        .resident_count = self.pressureBuffers.count,
    };
}

- (BOOL)openPlacementHeapWithSize:(NSUInteger)size
                      storageMode:(MTLStorageMode)storageMode
                            error:(NSError **)error
{
    if (error)
        *error = nil;
    if (!size)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorInvalidConfiguration,
                              @"placement heap size must be nonzero");
        return NO;
    }
    if (self.placementHeap)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorPlacementHeapBusy,
                              @"a placement heap is already open");
        return NO;
    }

    MTLHeapDescriptor *descriptor = [MTLHeapDescriptor new];
    descriptor.type = MTLHeapTypePlacement;
    descriptor.storageMode = storageMode;
    descriptor.size = size;
    id<MTLHeap> heap = [self.device newHeapWithDescriptor:descriptor];
    if (!heap)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorAllocationFailed,
                              @"Metal rejected the placement heap");
        return NO;
    }
    self.placementHeap = heap;
    self.placementHeapSize = size;
    return YES;
}

- (BOOL)closePlacementHeap:(NSError **)error
{
    if (error)
        *error = nil;
    if (self.activePlacements.count)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorPlacementHeapBusy,
                              @"active placement leases must retire before the heap closes");
        return NO;
    }
    self.placementHeap = nil;
    self.placementHeapSize = 0;
    return YES;
}

- (uint64_t)takeGeneration
{
    uint64_t generation = self.nextGeneration;
    if (self.nextGeneration != UINT64_MAX)
        self.nextGeneration++;
    return generation;
}

- (nullable AM12ResidencyLease *)newCommittedBufferWithLength:(NSUInteger)length
                                                      options:(MTLResourceOptions)options
{
    if (!length)
        return nil;
    id<MTLBuffer> buffer = [self.device newBufferWithLength:length options:options];
    if (!buffer)
        return nil;
    return [[AM12ResidencyLease alloc] initWithResource:buffer
                                                manager:self
                                                 placed:NO
                                                 offset:0
                                                 length:length
                                             generation:[self takeGeneration]];
}

- (BOOL)validatePlacementSize:(NSUInteger)size
                    alignment:(NSUInteger)alignment
                       offset:(NSUInteger)offset
                        error:(NSError **)error
{
    if (!self.placementHeap)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorPlacementHeapUnavailable,
                              @"no placement heap is open");
        return NO;
    }
    if (!size || !alignment || offset % alignment || offset > self.placementHeapSize ||
        size > self.placementHeapSize - offset)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorPlacementOutOfBounds,
                              @"placement range or alignment exceeds the heap");
        return NO;
    }
    return YES;
}

- (BOOL)rangesOverlapFrom:(NSUInteger)leftOffset
                   length:(NSUInteger)leftLength
               withOffset:(NSUInteger)rightOffset
                   length:(NSUInteger)rightLength
{
    return leftOffset < rightOffset + rightLength && rightOffset < leftOffset + leftLength;
}

- (void)activatePlacementLease:(AM12ResidencyLease *)lease
{
    NSArray<AM12ResidencyLease *> *previous = self.activePlacements.copy;
    for (AM12ResidencyLease *active in previous)
        if ([self rangesOverlapFrom:active.heapOffset
                             length:active.heapLength
                         withOffset:lease.heapOffset
                             length:lease.heapLength])
        {
            [self retireLease:active];
            self.aliasRetirementCount = AM12SaturatingAdd(self.aliasRetirementCount, 1);
        }

    [self.activePlacements addObject:lease];
    self.activePlacedBytes = AM12SaturatingAdd(self.activePlacedBytes, lease.heapLength);
    self.cumulativePlacedBytes = AM12SaturatingAdd(self.cumulativePlacedBytes, lease.heapLength);
    self.placementCount = AM12SaturatingAdd(self.placementCount, 1);
}

- (nullable AM12ResidencyLease *)newPlacedBufferWithLength:(NSUInteger)length
                                                   options:(MTLResourceOptions)options
                                                    offset:(NSUInteger)offset
                                                     error:(NSError **)error
{
    if (error)
        *error = nil;
    if (!length)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorInvalidConfiguration,
                              @"placed buffer length must be nonzero");
        return nil;
    }

    MTLSizeAndAlign footprint = [self.device heapBufferSizeAndAlignWithLength:length
                                                                      options:options];
    if (![self validatePlacementSize:footprint.size
                           alignment:footprint.align
                              offset:offset
                               error:error])
        return nil;

    id<MTLBuffer> buffer = [self.placementHeap newBufferWithLength:length
                                                           options:options
                                                            offset:offset];
    if (!buffer)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorAllocationFailed,
                              @"Metal rejected the placed buffer");
        return nil;
    }
    AM12ResidencyLease *lease = [[AM12ResidencyLease alloc] initWithResource:buffer
                                                                     manager:self
                                                                      placed:YES
                                                                      offset:offset
                                                                      length:footprint.size
                                                                  generation:[self takeGeneration]];
    [self activatePlacementLease:lease];
    return lease;
}

- (nullable AM12ResidencyLease *)newPlacedTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
                                                         offset:(NSUInteger)offset
                                                          error:(NSError **)error
{
    if (error)
        *error = nil;
    if (!descriptor)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorInvalidConfiguration,
                              @"placed texture descriptor must be nonnull");
        return nil;
    }

    MTLSizeAndAlign footprint = [self.device heapTextureSizeAndAlignWithDescriptor:descriptor];
    if (![self validatePlacementSize:footprint.size
                           alignment:footprint.align
                              offset:offset
                               error:error])
        return nil;

    id<MTLTexture> texture = [self.placementHeap newTextureWithDescriptor:descriptor offset:offset];
    if (!texture)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorAllocationFailed,
                              @"Metal rejected the placed texture");
        return nil;
    }
    AM12ResidencyLease *lease = [[AM12ResidencyLease alloc] initWithResource:texture
                                                                     manager:self
                                                                      placed:YES
                                                                      offset:offset
                                                                      length:footprint.size
                                                                  generation:[self takeGeneration]];
    [self activatePlacementLease:lease];
    return lease;
}

- (BOOL)retireLease:(AM12ResidencyLease *)lease
{
    if (lease.manager != self || lease.isRetired)
        return NO;

    lease.retired = YES;
    if (lease.isPlaced)
    {
        NSUInteger index = [self.activePlacements indexOfObjectIdenticalTo:lease];
        if (index != NSNotFound)
        {
            [self.activePlacements removeObjectAtIndex:index];
            self.activePlacedBytes -= lease.heapLength;
        }
    }
    return YES;
}

- (nullable id<MTLBuffer>)touchCachedBufferForKey:(uint32_t)key
                                           length:(NSUInteger)length
                                          options:(MTLResourceOptions)options
                                     materializer:(AM12ResidencyBufferMaterializer)materializer
                                         checksum:(AM12ResidencyBufferChecksum)checksum
                                            error:(NSError **)error
{
    if (error)
        *error = nil;
    if (!self.cacheCapacity || !length || !materializer || !checksum)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorInvalidConfiguration,
                              @"cache capacity, length, and callbacks must be valid");
        return nil;
    }

    NSNumber *cacheKey = @(key);
    AM12ResidencyCacheExpectation *expected = self.cacheExpectations[cacheKey];
    if (expected && (expected.length != length || expected.options != options))
    {
        AM12SetResidencyError(error, AM12ResidencyErrorCacheShapeChanged,
                              @"a cache key cannot change buffer shape");
        return nil;
    }

    NSUInteger hit = NSNotFound;
    for (NSUInteger index = 0; index < self.residentCache.count; index++)
        if (self.residentCache[index].key == key)
        {
            hit = index;
            break;
        }
    if (hit != NSNotFound)
    {
        AM12ResidencyCacheEntry *entry = self.residentCache[hit];
        [self.residentCache removeObjectAtIndex:hit];
        [self.residentCache addObject:entry];
        return entry.buffer;
    }

    while (self.residentCache.count >= self.cacheCapacity)
    {
        [self.residentCache removeObjectAtIndex:0];
        self.cacheEvictionCount = AM12SaturatingAdd(self.cacheEvictionCount, 1);
    }

    id<MTLBuffer> buffer = [self.device newBufferWithLength:length options:options];
    if (!buffer)
    {
        AM12SetResidencyError(error, AM12ResidencyErrorAllocationFailed,
                              @"Metal rejected a cache materialization buffer");
        return nil;
    }

    uint64_t materializedChecksum = materializer(buffer, key);
    if (expected && expected.checksum != materializedChecksum)
    {
        self.cacheMismatchCount = AM12SaturatingAdd(self.cacheMismatchCount, 1);
        AM12SetResidencyError(error, AM12ResidencyErrorChecksumMismatch,
                              @"rematerialized bytes differ from the recorded checksum");
        return nil;
    }
    if (expected)
        self.cacheRematerializationCount = AM12SaturatingAdd(self.cacheRematerializationCount, 1);

    uint64_t observedChecksum = checksum(buffer);
    if (observedChecksum != materializedChecksum)
    {
        self.cacheMismatchCount = AM12SaturatingAdd(self.cacheMismatchCount, 1);
        AM12SetResidencyError(error, AM12ResidencyErrorChecksumMismatch,
                              @"materialized bytes fail immediate checksum verification");
        return nil;
    }

    if (!expected)
    {
        expected = [AM12ResidencyCacheExpectation new];
        expected.length = length;
        expected.options = options;
        expected.checksum = materializedChecksum;
        self.cacheExpectations[cacheKey] = expected;
    }

    AM12ResidencyCacheEntry *entry = [AM12ResidencyCacheEntry new];
    entry.key = key;
    entry.length = length;
    entry.options = options;
    entry.buffer = buffer;
    [self.residentCache addObject:entry];
    return buffer;
}

- (void)clearResidentCache
{
    [self.residentCache removeAllObjects];
}

- (AM12ResidencyPressureDecision)
    pressureDecisionForCurrentAllocatedBytes:(uint64_t)currentAllocatedBytes
                        availableSystemBytes:(uint64_t)availableSystemBytes
{
    if (currentAllocatedBytes >= self.pressureTargetBytes)
        return AM12ResidencyPressureDecisionReachedTarget;
    if (availableSystemBytes < self.pressurePolicy.bailout_floor_bytes)
        return AM12ResidencyPressureDecisionBailOut;
    return AM12ResidencyPressureDecisionContinue;
}

- (nullable id<MTLBuffer>)allocatePressureBufferWithLength:(NSUInteger)length
                                                   options:(MTLResourceOptions)options
{
    id<MTLBuffer> buffer = [self.device newBufferWithLength:length options:options];
    if (!buffer)
    {
        self.pressureAllocationFailureCount =
            AM12SaturatingAdd(self.pressureAllocationFailureCount, 1);
        NSUInteger batch = self.pressurePolicy.eviction_batch_count;
        if (batch && self.pressureBuffers.count >= batch)
        {
            [self.pressureBuffers removeObjectsInRange:NSMakeRange(0, batch)];
            buffer = [self.device newBufferWithLength:length options:options];
            if (buffer)
                self.pressureEvictRetryRecoveryCount =
                    AM12SaturatingAdd(self.pressureEvictRetryRecoveryCount, 1);
        }
    }
    if (!buffer)
        return nil;

    [self.pressureBuffers addObject:buffer];
    self.pressureSuccessfulAllocationBytes =
        AM12SaturatingAdd(self.pressureSuccessfulAllocationBytes, length);
    return buffer;
}

- (void)clearPressureAllocations
{
    [self.pressureBuffers removeAllObjects];
}

@end
