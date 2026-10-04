/*
 * Internal Metal12 unified-memory residency manager.
 * Author: Timur Isaev
 */

#ifndef AM12_RESIDENCY_MANAGER_H
#define AM12_RESIDENCY_MANAGER_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct AM12ResidencyBudget
{
    uint64_t recommended_max_working_set_bytes;
    uint64_t current_allocated_bytes;
    uint64_t available_for_reservation_bytes;
} AM12ResidencyBudget;

typedef struct AM12ResidencyPlacementStats
{
    uint64_t active_placed_bytes;
    uint64_t cumulative_placed_bytes;
    uint64_t placement_count;
    uint64_t alias_retirement_count;
} AM12ResidencyPlacementStats;

typedef struct AM12ResidencyCacheStats
{
    uint64_t eviction_count;
    uint64_t rematerialization_count;
    uint64_t mismatch_count;
    uint64_t resident_count;
} AM12ResidencyCacheStats;

typedef struct AM12ResidencyPressurePolicy
{
    uint64_t oversubscription_margin_bytes;
    uint64_t bailout_floor_bytes;
    NSUInteger eviction_batch_count;
} AM12ResidencyPressurePolicy;

typedef struct AM12ResidencyPressureStats
{
    uint64_t allocation_failure_count;
    uint64_t evict_retry_recovery_count;
    uint64_t successful_allocation_bytes;
    uint64_t resident_count;
} AM12ResidencyPressureStats;

typedef NS_ENUM(NSInteger, AM12ResidencyPressureDecision) {
    AM12ResidencyPressureDecisionContinue = 0,
    AM12ResidencyPressureDecisionReachedTarget = 1,
    AM12ResidencyPressureDecisionBailOut = 2,
};

typedef NS_ENUM(NSInteger, AM12ResidencyErrorCode) {
    AM12ResidencyErrorInvalidConfiguration = 1,
    AM12ResidencyErrorPlacementHeapUnavailable = 2,
    AM12ResidencyErrorPlacementOutOfBounds = 3,
    AM12ResidencyErrorAllocationFailed = 4,
    AM12ResidencyErrorCacheShapeChanged = 5,
    AM12ResidencyErrorChecksumMismatch = 6,
    AM12ResidencyErrorPlacementHeapBusy = 7,
};

FOUNDATION_EXPORT NSString *const AM12ResidencyErrorDomain;

typedef uint64_t (^AM12ResidencyBufferMaterializer)(id<MTLBuffer> buffer, uint32_t key);
typedef uint64_t (^AM12ResidencyBufferChecksum)(id<MTLBuffer> buffer);

/*
 * A lease is the lifetime authority for one committed or placed resource.
 * Activating an overlapping placement retires the earlier lease before the
 * replacement becomes visible through the manager.
 */
@interface AM12ResidencyLease : NSObject

@property(nonatomic, strong, readonly) id<MTLResource> resource;
@property(nonatomic, readonly, getter=isPlaced) BOOL placed;
@property(nonatomic, readonly, getter=isRetired) BOOL retired;
@property(nonatomic, readonly) NSUInteger heapOffset;
@property(nonatomic, readonly) NSUInteger heapLength;
@property(nonatomic, readonly) uint64_t generation;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface AM12ResidencyManager : NSObject

@property(nonatomic, strong, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) NSUInteger cacheCapacity;
@property(nonatomic, readonly) AM12ResidencyPressurePolicy pressurePolicy;
@property(nonatomic, readonly) uint64_t pressureTargetBytes;
@property(nonatomic, readonly) AM12ResidencyPlacementStats placementStats;
@property(nonatomic, readonly) AM12ResidencyCacheStats cacheStats;
@property(nonatomic, readonly) AM12ResidencyPressureStats pressureStats;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDevice:(id<MTLDevice>)device
                 cacheCapacity:(NSUInteger)cacheCapacity
                pressurePolicy:(AM12ResidencyPressurePolicy)pressurePolicy
    NS_DESIGNATED_INITIALIZER;

- (AM12ResidencyBudget)budgetSnapshot;

- (BOOL)openPlacementHeapWithSize:(NSUInteger)size
                      storageMode:(MTLStorageMode)storageMode
                            error:(NSError *_Nullable *_Nullable)error;
- (BOOL)closePlacementHeap:(NSError *_Nullable *_Nullable)error;

- (nullable AM12ResidencyLease *)newCommittedBufferWithLength:(NSUInteger)length
                                                      options:(MTLResourceOptions)options;
- (nullable AM12ResidencyLease *)newPlacedBufferWithLength:(NSUInteger)length
                                                   options:(MTLResourceOptions)options
                                                    offset:(NSUInteger)offset
                                                     error:(NSError *_Nullable *_Nullable)error;
- (nullable AM12ResidencyLease *)newPlacedTextureWithDescriptor:(MTLTextureDescriptor *)descriptor
                                                         offset:(NSUInteger)offset
                                                          error:
                                                              (NSError *_Nullable *_Nullable)error;
- (BOOL)retireLease:(AM12ResidencyLease *)lease;

- (nullable id<MTLBuffer>)touchCachedBufferForKey:(uint32_t)key
                                           length:(NSUInteger)length
                                          options:(MTLResourceOptions)options
                                     materializer:(AM12ResidencyBufferMaterializer)materializer
                                         checksum:(AM12ResidencyBufferChecksum)checksum
                                            error:(NSError *_Nullable *_Nullable)error;
- (void)clearResidentCache;

- (AM12ResidencyPressureDecision)
    pressureDecisionForCurrentAllocatedBytes:(uint64_t)currentAllocatedBytes
                        availableSystemBytes:(uint64_t)availableSystemBytes;
- (nullable id<MTLBuffer>)allocatePressureBufferWithLength:(NSUInteger)length
                                                   options:(MTLResourceOptions)options;
- (void)clearPressureAllocations;

@end

NS_ASSUME_NONNULL_END

#endif
