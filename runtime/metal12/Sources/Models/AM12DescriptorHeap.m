/*
 * Metal12 reusable descriptor heap and argument-page model.
 * Author: Timur Isaev
 */

#import "AM12DescriptorHeap.h"

#include <limits.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>

typedef struct AM12DescriptorPageMetadata
{
    _Atomic int in_flight;
    _Atomic bool cached;
    _Atomic bool leased;
    uint32_t next_free;
    uint64_t serial;
} AM12DescriptorPageMetadata;

@interface AM12DescriptorHeapStorage : NSObject
{
  @public
    id<MTLDevice> device;
    id<MTLBuffer> poison_buffer;
    AM12DescriptorHeapConfiguration configuration;
    AM12HeapDescriptorRecord *slots;
    AM12DescriptorPageMetadata *pages;
    NSMutableArray *resource_buffers;
    NSMutableArray<id<MTLBuffer>> *page_buffers;
    NSLock *pool_lock;
    dispatch_semaphore_t free_pages;
    uint32_t free_head;
    uint64_t next_generation;
    BOOL cache_valid;
    AM12DescriptorTable cached_table;
    uint64_t descriptor_writes;
    uint64_t descriptor_copies;
    uint64_t cache_hits;
    uint64_t cache_misses;
    uint64_t encoded_descriptors;
    uint64_t encode_nanoseconds;
    uint64_t page_stalls;
    _Atomic uint32_t pages_in_flight;
    _Atomic uint32_t max_pages_in_flight;
}
@end

@implementation AM12DescriptorHeapStorage

- (void)dealloc
{
    free(slots);
    free(pages);
}

@end

@interface AM12DescriptorHeap ()

@property(nonatomic, strong) AM12DescriptorHeapStorage *storage;

@end

static double AM12DescriptorTimebaseNanoseconds(void)
{
    static mach_timebase_info_data_t info;

    if (!info.denom)
        mach_timebase_info(&info);
    return (double)info.numer / (double)info.denom;
}

static BOOL AM12DescriptorRangeIsValid(uint32_t start, uint32_t count, uint32_t capacity)
{
    return start <= capacity && count <= capacity - start;
}

static id<MTLBuffer> AM12DescriptorResolveResource(AM12DescriptorHeapStorage *storage,
                                                   uint32_t resourceIdentifier)
{
    if (resourceIdentifier == storage->configuration.invalid_resource_identifier)
        return storage->poison_buffer;
    if (resourceIdentifier >= storage->configuration.resource_capacity)
        return nil;

    id value = storage->resource_buffers[resourceIdentifier];
    return value == [NSNull null] ? nil : (id<MTLBuffer>)value;
}

static uint64_t AM12DescriptorTakeGeneration(AM12DescriptorHeapStorage *storage)
{
    uint64_t generation = storage->next_generation;

    storage->next_generation++;
    return generation;
}

@implementation AM12DescriptorHeap

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                          configuration:(AM12DescriptorHeapConfiguration)configuration
                           poisonBuffer:(id<MTLBuffer>)poisonBuffer
{
    if (!device || !poisonBuffer || poisonBuffer.device != device || !configuration.slot_count ||
        !configuration.resource_capacity || !configuration.page_entry_count ||
        !configuration.page_count ||
        configuration.invalid_resource_identifier < configuration.resource_capacity)
        return nil;

    self = [super init];
    if (!self)
        return nil;

    AM12DescriptorHeapStorage *storage = [AM12DescriptorHeapStorage new];
    storage->device = device;
    storage->poison_buffer = poisonBuffer;
    storage->configuration = configuration;
    storage->slots = calloc((size_t)configuration.slot_count, sizeof(*storage->slots));
    storage->pages = calloc((size_t)configuration.page_count, sizeof(*storage->pages));
    if (!storage->slots || !storage->pages)
        return nil;

    storage->resource_buffers = [NSMutableArray arrayWithCapacity:configuration.resource_capacity];
    for (uint32_t resource = 0; resource < configuration.resource_capacity; resource++)
        [storage->resource_buffers addObject:[NSNull null]];

    storage->page_buffers = [NSMutableArray arrayWithCapacity:configuration.page_count];
    storage->pool_lock = [NSLock new];
    storage->free_pages = dispatch_semaphore_create(0);
    storage->free_head = 0;
    storage->next_generation = 1;

    uint64_t poisonAddress = poisonBuffer.gpuAddress;
    NSUInteger pageBytes = (NSUInteger)configuration.page_entry_count * sizeof(uint64_t);
    for (uint32_t page = 0; page < configuration.page_count; page++)
    {
        id<MTLBuffer> buffer = [device newBufferWithLength:pageBytes
                                                   options:MTLResourceStorageModeShared];
        if (!buffer)
            return nil;

        uint64_t *entries = (uint64_t *)buffer.contents;
        for (uint32_t entry = 0; entry < configuration.page_entry_count; entry++)
            entries[entry] = poisonAddress;
        [storage->page_buffers addObject:buffer];

        atomic_init(&storage->pages[page].in_flight, 0);
        atomic_init(&storage->pages[page].cached, false);
        atomic_init(&storage->pages[page].leased, false);
        storage->pages[page].next_free =
            page + 1u < configuration.page_count ? page + 1u : UINT32_MAX;
        dispatch_semaphore_signal(storage->free_pages);
    }
    atomic_init(&storage->pages_in_flight, 0);
    atomic_init(&storage->max_pages_in_flight, 0);

    for (uint32_t slot = 0; slot < configuration.slot_count; slot++)
    {
        storage->slots[slot].resource_identifier = configuration.invalid_resource_identifier;
        storage->slots[slot].generation = 0;
    }

    self.storage = storage;
    return self;
}

- (AM12DescriptorHeapConfiguration)configuration
{
    return self.storage->configuration;
}

- (BOOL)registerBuffer:(id<MTLBuffer>)buffer forResourceIdentifier:(uint32_t)resourceIdentifier
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (!buffer || buffer.device != storage->device ||
        resourceIdentifier >= storage->configuration.resource_capacity ||
        resourceIdentifier == storage->configuration.invalid_resource_identifier)
        return NO;

    storage->resource_buffers[resourceIdentifier] = buffer;
    return YES;
}

- (nullable id<MTLBuffer>)bufferForResourceIdentifier:(uint32_t)resourceIdentifier
{
    return AM12DescriptorResolveResource(self.storage, resourceIdentifier);
}

- (BOOL)writeResourceIdentifier:(uint32_t)resourceIdentifier
                         atSlot:(uint32_t)slot
                     generation:(nullable uint64_t *)generation
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (slot >= storage->configuration.slot_count ||
        !AM12DescriptorResolveResource(storage, resourceIdentifier))
        return NO;

    uint64_t nextGeneration = AM12DescriptorTakeGeneration(storage);
    storage->slots[slot] = (AM12HeapDescriptorRecord){
        .resource_identifier = resourceIdentifier,
        .generation = nextGeneration,
    };
    storage->descriptor_writes++;
    if (generation)
        *generation = nextGeneration;
    return YES;
}

- (BOOL)copyDescriptorsFromSlot:(uint32_t)sourceSlot
                         toSlot:(uint32_t)destinationSlot
                          count:(uint32_t)count
{
    AM12DescriptorHeapStorage *storage = self.storage;
    uint32_t slotCount = storage->configuration.slot_count;
    if (!AM12DescriptorRangeIsValid(sourceSlot, count, slotCount) ||
        !AM12DescriptorRangeIsValid(destinationSlot, count, slotCount))
        return NO;

    /*
     * Deliberately forward, matching D3D12's sequential descriptor-copy
     * model and the original proof's behavior for overlapping ranges.
     */
    for (uint32_t index = 0; index < count; index++)
    {
        storage->slots[destinationSlot + index] = storage->slots[sourceSlot + index];
        storage->slots[destinationSlot + index].generation = AM12DescriptorTakeGeneration(storage);
    }
    storage->descriptor_copies += count;
    return YES;
}

- (BOOL)descriptorAtSlot:(uint32_t)slot record:(AM12HeapDescriptorRecord *)record
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (!record || slot >= storage->configuration.slot_count)
        return NO;

    *record = storage->slots[slot];
    return YES;
}

- (uint32_t)allocatePage
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (dispatch_semaphore_wait(storage->free_pages, DISPATCH_TIME_NOW))
    {
        storage->page_stalls++;
        dispatch_semaphore_wait(storage->free_pages, DISPATCH_TIME_FOREVER);
    }

    [storage->pool_lock lock];
    uint32_t pageIndex = storage->free_head;
    if (pageIndex == UINT32_MAX)
    {
        [storage->pool_lock unlock];
        dispatch_semaphore_signal(storage->free_pages);
        return UINT32_MAX;
    }
    AM12DescriptorPageMetadata *page = &storage->pages[pageIndex];
    storage->free_head = page->next_free;
    page->next_free = UINT32_MAX;
    page->serial++;
    if (!page->serial)
        page->serial++;
    atomic_store(&page->leased, true);
    [storage->pool_lock unlock];
    return pageIndex;
}

- (void)releasePageAtIndex:(uint32_t)pageIndex
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (pageIndex >= storage->configuration.page_count)
        return;

    AM12DescriptorPageMetadata *page = &storage->pages[pageIndex];
    bool expected = true;
    if (!atomic_compare_exchange_strong(&page->leased, &expected, false))
        return;

    [storage->pool_lock lock];
    uint64_t poisonAddress = storage->poison_buffer.gpuAddress;
    id<MTLBuffer> buffer = storage->page_buffers[pageIndex];
    uint64_t *entries = (uint64_t *)buffer.contents;
    for (uint32_t entry = 0; entry < storage->configuration.page_entry_count; entry++)
        entries[entry] = poisonAddress;
    page->next_free = storage->free_head;
    storage->free_head = pageIndex;
    [storage->pool_lock unlock];
    dispatch_semaphore_signal(storage->free_pages);
}

- (BOOL)materializeTableAtOffset:(uint32_t)offset
                           count:(uint32_t)count
                           table:(AM12DescriptorTable *)table
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (!table || !count || count > storage->configuration.page_entry_count ||
        !AM12DescriptorRangeIsValid(offset, count, storage->configuration.slot_count))
        return NO;

    uint64_t generationSum = 0;
    for (uint32_t index = 0; index < count; index++)
        generationSum += storage->slots[offset + index].generation;

    if (storage->cache_valid && storage->cached_table.heap_offset == offset &&
        storage->cached_table.descriptor_count == count &&
        storage->cached_table.generation_sum == generationSum)
    {
        *table = storage->cached_table;
        table->cache_hit = true;
        storage->cache_hits++;
        return YES;
    }

    uint64_t encodeStart = mach_absolute_time();
    uint32_t pageIndex = [self allocatePage];
    if (pageIndex == UINT32_MAX)
        return NO;

    id<MTLBuffer> pageBuffer = storage->page_buffers[pageIndex];
    uint64_t *entries = (uint64_t *)pageBuffer.contents;
    for (uint32_t index = 0; index < count; index++)
    {
        id<MTLBuffer> resource = AM12DescriptorResolveResource(
            storage, storage->slots[offset + index].resource_identifier);
        if (!resource)
        {
            [self releasePageAtIndex:pageIndex];
            return NO;
        }
        entries[index] = resource.gpuAddress;
    }

    uint64_t elapsed = mach_absolute_time() - encodeStart;
    storage->encode_nanoseconds +=
        (uint64_t)((double)elapsed * AM12DescriptorTimebaseNanoseconds());
    storage->encoded_descriptors += count;
    storage->cache_misses++;

    if (storage->cache_valid)
    {
        uint32_t previousPageIndex = storage->cached_table.page_index;
        AM12DescriptorPageMetadata *previousPage = &storage->pages[previousPageIndex];
        atomic_store(&previousPage->cached, false);
        if (!atomic_load(&previousPage->in_flight))
            [self releasePageAtIndex:previousPageIndex];
    }

    AM12DescriptorPageMetadata *page = &storage->pages[pageIndex];
    AM12DescriptorTable newTable = {
        .page_index = pageIndex,
        .page_serial = page->serial,
        .heap_offset = offset,
        .descriptor_count = count,
        .generation_sum = generationSum,
        .cache_hit = false,
    };
    storage->cached_table = newTable;
    storage->cache_valid = YES;
    atomic_store(&page->cached, true);
    *table = newTable;
    return YES;
}

- (nullable id<MTLBuffer>)bufferForTable:(AM12DescriptorTable)table
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (table.page_index >= storage->configuration.page_count)
        return nil;

    AM12DescriptorPageMetadata *page = &storage->pages[table.page_index];
    if (!atomic_load(&page->leased) || page->serial != table.page_serial)
        return nil;
    return storage->page_buffers[table.page_index];
}

- (BOOL)retainTable:(AM12DescriptorTable)table
    untilCommandBufferCompletes:(id<MTLCommandBuffer>)commandBuffer
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (!commandBuffer || table.page_index >= storage->configuration.page_count)
        return NO;

    AM12DescriptorPageMetadata *page = &storage->pages[table.page_index];
    if (!atomic_load(&page->leased) || page->serial != table.page_serial)
        return NO;

    if (atomic_fetch_add(&page->in_flight, 1) == 0)
    {
        uint32_t now = atomic_fetch_add(&storage->pages_in_flight, 1) + 1u;
        uint32_t seenMaximum = atomic_load(&storage->max_pages_in_flight);
        while (now > seenMaximum &&
               !atomic_compare_exchange_weak(&storage->max_pages_in_flight, &seenMaximum, now))
            ;
    }

    uint32_t pageIndex = table.page_index;
    uint64_t pageSerial = table.page_serial;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
      (void)completed;
      AM12DescriptorHeapStorage *completedStorage = self.storage;
      AM12DescriptorPageMetadata *completedPage = &completedStorage->pages[pageIndex];
      if (completedPage->serial != pageSerial)
          return;
      if (atomic_fetch_sub(&completedPage->in_flight, 1) == 1)
      {
          atomic_fetch_sub(&completedStorage->pages_in_flight, 1);
          if (!atomic_load(&completedPage->cached))
              [self releasePageAtIndex:pageIndex];
      }
    }];
    return YES;
}

- (BOOL)forceRecycleTableImmediatelyForTesting:(AM12DescriptorTable)table
{
    AM12DescriptorHeapStorage *storage = self.storage;
    if (!storage->cache_valid || table.page_index >= storage->configuration.page_count ||
        storage->cached_table.page_index != table.page_index ||
        storage->cached_table.page_serial != table.page_serial)
        return NO;

    AM12DescriptorPageMetadata *page = &storage->pages[table.page_index];
    if (!atomic_load(&page->leased) || atomic_load(&page->in_flight))
        return NO;

    storage->cache_valid = NO;
    atomic_store(&page->cached, false);
    [self releasePageAtIndex:table.page_index];
    return YES;
}

- (AM12DescriptorHeapStatistics)statistics
{
    AM12DescriptorHeapStorage *storage = self.storage;
    return (AM12DescriptorHeapStatistics){
        .descriptor_writes = storage->descriptor_writes,
        .descriptor_copies = storage->descriptor_copies,
        .cache_hits = storage->cache_hits,
        .cache_misses = storage->cache_misses,
        .encoded_descriptors = storage->encoded_descriptors,
        .encode_nanoseconds = storage->encode_nanoseconds,
        .page_stalls = storage->page_stalls,
        .pages_in_flight = atomic_load(&storage->pages_in_flight),
        .max_pages_in_flight = atomic_load(&storage->max_pages_in_flight),
    };
}

@end
