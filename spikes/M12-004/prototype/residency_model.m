/*
 * M12-004 unified-memory residency prototype.
 * Author: Tim Isaev
 *
 * Exercises a D3D12-style virtual memory model on Apple unified memory:
 * committed buffers vs placement-heap sub-allocations, the aliasing
 * lifetime rule proven by observation, budget synthesis from Metal's
 * working-set numbers, a pressure-driven LRU chunk cache with checksummed
 * rematerialization, long-session churn with bounded growth, and a
 * bail-out-guarded oversubscription push with evict-and-retry recovery.
 *
 * Provenance: ADR-0012 discipline model; see ../PROVENANCE.md.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach/mach_time.h>
#include <mach/mach.h>
#include <stdlib.h>

#define CHUNK_MB 64
#define CHUNK_BYTES ((size_t)CHUNK_MB << 20)
#define PAGE_STRIDE 16384
#define CHURN_ITERATIONS 20000
#define BAILOUT_FLOOR ((size_t)2 << 30) /* stop pushing if less remains */

static size_t available_memory(void)
{
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;

    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) !=
        KERN_SUCCESS)
        return 0;
    return ((size_t)vm.free_count + vm.inactive_count) * vm_kernel_page_size;
}

/* Metal reclaims released allocations asynchronously; settle before measuring */
static uint64_t drain(id<MTLDevice> device)
{
    uint64_t prev = device.currentAllocatedSize;

    for (int i = 0; i < 50; i++)
    {
        usleep(100 * 1000);
        uint64_t now = device.currentAllocatedSize;
        if (now == prev && i > 3)
            break;
        prev = now;
    }
    return prev;
}

static uint64_t footprint(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    return info.phys_footprint;
}

static double mb(uint64_t bytes)
{
    return (double)bytes / (1024.0 * 1024.0);
}

/* deterministic chunk content: one word per page, LCG-seeded by chunk id */
static uint64_t fill_chunk(id<MTLBuffer> buffer, uint32_t id_)
{
    uint8_t *base = buffer.contents;
    uint64_t checksum = 0;
    uint32_t v = id_ * 2654435761u + 1;

    for (size_t off = 0; off < CHUNK_BYTES; off += PAGE_STRIDE)
    {
        v = v * 1664525u + 1013904223u;
        *(uint32_t *)(base + off) = v;
        checksum += v;
    }
    return checksum;
}

static uint64_t sum_chunk(id<MTLBuffer> buffer)
{
    uint8_t *base = buffer.contents;
    uint64_t checksum = 0;

    for (size_t off = 0; off < CHUNK_BYTES; off += PAGE_STRIDE)
        checksum += *(uint32_t *)(base + off);
    return checksum;
}

int main(void)
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            puts("no metal device");
            return 1;
        }

        /* --- budget reporting ------------------------------------------- */
        uint64_t budget = device.recommendedMaxWorkingSetSize;
        uint64_t baseline = device.currentAllocatedSize;
        printf("budget: recommended max %.0f MB, baseline usage %.1f MB, "
               "available-for-reservation %.0f MB\n",
               mb(budget), mb(baseline), mb(budget - baseline));

        /* --- committed vs placed + aliasing lifetime -------------------- */
        @autoreleasepool
        {
            MTLHeapDescriptor *heap_desc = [MTLHeapDescriptor new];
            heap_desc.type = MTLHeapTypePlacement;
            heap_desc.storageMode = MTLStorageModeShared;
            heap_desc.size = 64 << 20;
            id<MTLHeap> heap = [device newHeapWithDescriptor:heap_desc];
            if (!heap)
            {
                puts("placement heap creation failed");
                return 2;
            }
            id<MTLBuffer> committed = [device newBufferWithLength:1 << 20
                                                          options:MTLResourceStorageModeShared];
            id<MTLBuffer> placed_a = [heap newBufferWithLength:8 << 20
                                                       options:MTLResourceStorageModeShared
                                                        offset:0];
            memset(committed.contents, 0x11, 1 << 20);
            memset(placed_a.contents, 0xAA, 8 << 20);

            /* activate B over the same range; A's bytes must be observably gone
             * after B writes - the model MUST retire A on alias activation */
            id<MTLBuffer> placed_b = [heap newBufferWithLength:8 << 20
                                                       options:MTLResourceStorageModeShared
                                                        offset:0];
            memset(placed_b.contents, 0xBB, 8 << 20);
            uint8_t stale = ((uint8_t *)placed_a.contents)[4096];
            printf("aliasing: A@0 then B@0 written; A now reads 0x%02X %s\n", stale,
                   stale == 0xBB ? "(overlap real, retire rule load-bearing)"
                                 : "(UNEXPECTED - no overlap?)");
            if (stale != 0xBB)
                return 3;
            placed_a = nil;
            placed_b = nil;
            committed = nil;
            heap = nil;
        }

        /* --- pressure-aware LRU chunk cache ----------------------------- */
        uint32_t cache_capacity = 12; /* 768 MB target working set */
        NSMutableArray<id<MTLBuffer>> *cache = [NSMutableArray array];
        NSMutableArray<NSNumber *> *cache_ids = [NSMutableArray array];
        static uint64_t checksums[4096];
        uint32_t evictions = 0, rematerializations = 0, mismatches = 0;

        for (uint32_t touch = 0; touch < 200; touch++)
        {
            @autoreleasepool
            {
                uint32_t chunk = random() % 40;
                NSUInteger found = [cache_ids indexOfObject:@(chunk)];

                if (found != NSNotFound)
                {
                    /* LRU refresh */
                    id<MTLBuffer> buf = cache[found];
                    [cache removeObjectAtIndex:found];
                    [cache_ids removeObjectAtIndex:found];
                    [cache addObject:buf];
                    [cache_ids addObject:@(chunk)];
                    continue;
                }
                while (cache.count >= cache_capacity)
                {
                    [cache removeObjectAtIndex:0];
                    [cache_ids removeObjectAtIndex:0];
                    evictions++;
                }
                id<MTLBuffer> buf = [device newBufferWithLength:CHUNK_BYTES
                                                        options:MTLResourceStorageModeShared];
                if (!buf)
                {
                    puts("cache allocation failed under normal pressure");
                    return 4;
                }
                uint64_t sum = fill_chunk(buf, chunk);
                if (checksums[chunk] && checksums[chunk] != sum)
                    mismatches++;
                else if (checksums[chunk])
                    rematerializations++;
                checksums[chunk] = sum;
                if (sum_chunk(buf) != sum)
                    mismatches++;
                [cache addObject:buf];
                [cache_ids addObject:@(chunk)];
            }
        }
        printf("eviction cache: %u evictions, %u rematerializations verified, %u mismatches\n",
               evictions, rematerializations, mismatches);
        if (mismatches)
            return 5;
        [cache removeAllObjects];
        [cache_ids removeAllObjects];

        /* --- long-session churn ------------------------------------------ */
        uint64_t churn_start = drain(device);
        uint64_t peak = churn_start;
        NSMutableArray<id<MTLBuffer>> *pool = [NSMutableArray array];
        uint64_t t0 = mach_absolute_time();

        for (uint32_t i = 0; i < CHURN_ITERATIONS; i++)
        {
            @autoreleasepool
            {
                if (pool.count > 96 || (pool.count && (random() & 1)))
                    [pool removeObjectAtIndex:random() % pool.count];
                else
                {
                    size_t size = (size_t)(1 + random() % 16) << 20;
                    id<MTLBuffer> buf = [device newBufferWithLength:size
                                                            options:MTLResourceStorageModeShared];
                    if (buf)
                    {
                        *(uint32_t *)buf.contents = i; /* touch first page */
                        [pool addObject:buf];
                    }
                }
            }
            if ((i & 1023) == 0)
            {
                uint64_t now = device.currentAllocatedSize;
                if (now > peak)
                    peak = now;
            }
        }
        uint64_t t1 = mach_absolute_time();
        [pool removeAllObjects];
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        uint64_t churn_end = drain(device);
        printf("long session: %u ops in %.1f s, peak %.0f MB, baseline %.1f -> %.1f MB "
               "(delta %.1f MB)\n",
               CHURN_ITERATIONS, (double)(t1 - t0) * tb.numer / tb.denom / 1e9, mb(peak),
               mb(churn_start), mb(churn_end), mb(churn_end - churn_start));
        if (churn_end > churn_start + (64 << 20))
        {
            puts("long-session growth exceeds 64 MB");
            return 6;
        }

        /* --- guarded oversubscription push ------------------------------- */
        NSMutableArray<id<MTLBuffer>> *pressure = [NSMutableArray array];
        uint64_t pushed = 0;
        uint32_t alloc_failures = 0, recovered = 0;
        int bailed = 0;
        uint64_t push_base = drain(device);
        uint64_t target = budget + ((uint64_t)1 << 30);

        printf("oversubscription base after drain: %.1f MB\n", mb(push_base));

        while (device.currentAllocatedSize < target)
        {
            @autoreleasepool
            {
                if (available_memory() < BAILOUT_FLOOR)
                {
                    bailed = 1;
                    break;
                }
                id<MTLBuffer> buf = [device newBufferWithLength:CHUNK_BYTES
                                                        options:MTLResourceStorageModeShared];
                if (!buf)
                {
                    alloc_failures++;
                    if (pressure.count >= 4)
                    {
                        /* graceful path: evict and retry once */
                        [pressure removeObjectsInRange:NSMakeRange(0, 4)];
                        buf = [device newBufferWithLength:CHUNK_BYTES
                                                  options:MTLResourceStorageModeShared];
                        if (buf)
                            recovered++;
                    }
                    if (!buf)
                        break;
                }
                /* touch a quarter of the pages: enough commit to be real without
                 * swamping the machine */
                uint8_t *base = buf.contents;
                for (size_t off = 0; off < CHUNK_BYTES; off += PAGE_STRIDE * 4)
                    base[off] = (uint8_t)off;
                pushed += CHUNK_BYTES;
                [pressure addObject:buf];
            }
        }
        uint64_t at_peak = device.currentAllocatedSize;
        [pressure removeAllObjects];
        uint64_t settled = drain(device);
        printf("oversubscription: pushed %.0f MB to %.0f MB allocated "
               "(budget %.0f), %u alloc failures, %u evict-retry recoveries, %s\n",
               mb(pushed), mb(at_peak), mb(budget), alloc_failures, recovered,
               bailed ? "bailed at system floor (graceful)" : "reached target");
        uint64_t foot_after = footprint();
        printf("post-release: metal allocated (drained) %.1f MB, process footprint %.1f MB\n",
               mb(settled), mb(foot_after));

        if (settled > push_base + (256 << 20))
        {
            puts("post-oversubscription memory did not return to baseline");
            return 7;
        }

        puts("m12-004 residency ok");
        return 0;
    }
}
