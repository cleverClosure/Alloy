/*
 * Metal12 reusable descriptor heap and argument-page model.
 * Author: Timur Isaev
 */

#ifndef AM12_DESCRIPTOR_HEAP_H
#define AM12_DESCRIPTOR_HEAP_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct AM12DescriptorHeapConfiguration
{
    uint32_t slot_count;
    uint32_t resource_capacity;
    uint32_t page_entry_count;
    uint32_t page_count;
    uint32_t invalid_resource_identifier;
} AM12DescriptorHeapConfiguration;

typedef struct AM12HeapDescriptorRecord
{
    uint32_t resource_identifier;
    uint64_t generation;
} AM12HeapDescriptorRecord;

typedef struct AM12DescriptorTable
{
    uint32_t page_index;
    uint64_t page_serial;
    uint32_t heap_offset;
    uint32_t descriptor_count;
    uint64_t generation_sum;
    bool cache_hit;
} AM12DescriptorTable;

typedef struct AM12DescriptorHeapStatistics
{
    uint64_t descriptor_writes;
    uint64_t descriptor_copies;
    uint64_t cache_hits;
    uint64_t cache_misses;
    uint64_t encoded_descriptors;
    uint64_t encode_nanoseconds;
    uint64_t page_stalls;
    uint32_t pages_in_flight;
    uint32_t max_pages_in_flight;
} AM12DescriptorHeapStatistics;

/*
 * Heap mutation and table materialization are serialized by the caller.
 * Command-buffer completion handlers may retire pages concurrently.
 */
@interface AM12DescriptorHeap : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                          configuration:(AM12DescriptorHeapConfiguration)configuration
                           poisonBuffer:(id<MTLBuffer>)poisonBuffer NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) AM12DescriptorHeapConfiguration configuration;

- (BOOL)registerBuffer:(id<MTLBuffer>)buffer forResourceIdentifier:(uint32_t)resourceIdentifier;

- (nullable id<MTLBuffer>)bufferForResourceIdentifier:(uint32_t)resourceIdentifier;

- (BOOL)writeResourceIdentifier:(uint32_t)resourceIdentifier
                         atSlot:(uint32_t)slot
                     generation:(nullable uint64_t *)generation;

- (BOOL)copyDescriptorsFromSlot:(uint32_t)sourceSlot
                         toSlot:(uint32_t)destinationSlot
                          count:(uint32_t)count;

- (BOOL)descriptorAtSlot:(uint32_t)slot record:(AM12HeapDescriptorRecord *)record;

- (BOOL)materializeTableAtOffset:(uint32_t)offset
                           count:(uint32_t)count
                           table:(AM12DescriptorTable *)table;

- (nullable id<MTLBuffer>)bufferForTable:(AM12DescriptorTable)table;

/*
 * Call once for each command buffer that consumes a materialized table.
 * The page remains alive until every registered consumer completes.
 */
- (BOOL)retainTable:(AM12DescriptorTable)table
    untilCommandBufferCompletes:(id<MTLCommandBuffer>)commandBuffer;

/*
 * Proof-only sensitivity hook. It deliberately violates the lifetime rule,
 * poisons the cached page, and returns it to the free ring immediately.
 */
- (BOOL)forceRecycleTableImmediatelyForTesting:(AM12DescriptorTable)table;

- (AM12DescriptorHeapStatistics)statistics;

@end

NS_ASSUME_NONNULL_END

#endif
