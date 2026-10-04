/*
 * M12-004 unified-memory residency runtime proof.
 * Author: Timur Isaev
 *
 * Exercises a D3D12-style virtual memory model on Apple unified memory:
 * committed buffers vs placement-heap sub-allocations, the aliasing
 * lifetime rule proven by observation, budget synthesis from Metal's
 * working-set numbers, a pressure-driven LRU chunk cache with checksummed
 * rematerialization, long-session churn with bounded growth, and a
 * bail-out-guarded oversubscription push with evict-and-retry recovery.
 *
 * Provenance: ADR-0012 discipline model; see ../../PROVENANCE.md.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "../Models/AM12ResidencyManager.h"

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHUNK_MB 64
#define CHUNK_BYTES ((size_t)CHUNK_MB << 20)
#define PAGE_STRIDE 16384
#define CHURN_ITERATIONS 20000
#define CACHE_CAPACITY 12
#define CACHE_TOUCHES 200
#define CACHE_WORKING_SET 40
#define PLACEMENT_HEAP_BYTES ((size_t)64 << 20)
#define PRESSURE_MARGIN_BYTES ((uint64_t)1 << 30)
#define PRESSURE_EVICTION_BATCH 4
#define BAILOUT_FLOOR_BYTES ((uint64_t)2 << 30) /* stop pushing if less remains */

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

static int run_residency_proof(BOOL include_pressure)
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            puts("no metal device");
            return 1;
        }

        AM12ResidencyPressurePolicy pressure_policy = {
            .oversubscription_margin_bytes = PRESSURE_MARGIN_BYTES,
            .bailout_floor_bytes = BAILOUT_FLOOR_BYTES,
            .eviction_batch_count = PRESSURE_EVICTION_BATCH,
        };
        AM12ResidencyManager *residency =
            [[AM12ResidencyManager alloc] initWithDevice:device
                                           cacheCapacity:CACHE_CAPACITY
                                          pressurePolicy:pressure_policy];

        /* --- budget reporting ------------------------------------------- */
        AM12ResidencyBudget budget = residency.budgetSnapshot;
        printf("budget: recommended max %.0f MB, baseline usage %.1f MB, "
               "available-for-reservation %.0f MB\n",
               mb(budget.recommended_max_working_set_bytes), mb(budget.current_allocated_bytes),
               mb(budget.available_for_reservation_bytes));

        /* --- committed vs placed + aliasing lifetime -------------------- */
        NSError *error = nil;
        if (![residency openPlacementHeapWithSize:PLACEMENT_HEAP_BYTES
                                      storageMode:MTLStorageModeShared
                                            error:&error])
        {
            printf("placement heap creation failed: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        @autoreleasepool
        {
            AM12ResidencyLease *committed_lease =
                [residency newCommittedBufferWithLength:1 << 20
                                                options:MTLResourceStorageModeShared];
            AM12ResidencyLease *placed_a_lease =
                [residency newPlacedBufferWithLength:8 << 20
                                             options:MTLResourceStorageModeShared
                                              offset:0
                                               error:&error];
            if (!committed_lease || !placed_a_lease)
            {
                printf("initial residency allocation failed: %s\n",
                       error.localizedDescription.UTF8String ?: "committed buffer");
                return 2;
            }
            id<MTLBuffer> committed = (id<MTLBuffer>)committed_lease.resource;
            id<MTLBuffer> placed_a = (id<MTLBuffer>)placed_a_lease.resource;
            memset(committed.contents, 0x11, 1 << 20);
            memset(placed_a.contents, 0xAA, 8 << 20);

            /* activate B over the same range; A's bytes must be observably gone
             * after B writes - the model MUST retire A on alias activation */
            AM12ResidencyLease *placed_b_lease =
                [residency newPlacedBufferWithLength:8 << 20
                                             options:MTLResourceStorageModeShared
                                              offset:0
                                               error:&error];
            if (!placed_b_lease)
            {
                printf("alias placement failed: %s\n", error.localizedDescription.UTF8String);
                return 3;
            }
            id<MTLBuffer> placed_b = (id<MTLBuffer>)placed_b_lease.resource;
            memset(placed_b.contents, 0xBB, 8 << 20);
            uint8_t stale = ((uint8_t *)placed_a.contents)[4096];
            AM12ResidencyPlacementStats placement_stats = residency.placementStats;
            BOOL alias_retired = placed_a_lease.isRetired && !placed_b_lease.isRetired &&
                                 placement_stats.alias_retirement_count == 1;
            printf("aliasing: A@0 then B@0 written; A now reads 0x%02X %s\n", stale,
                   stale == 0xBB && alias_retired ? "(overlap real, retire rule load-bearing)"
                                                  : "(UNEXPECTED - overlap or retire rule failed)");
            if (stale != 0xBB || !alias_retired)
                return 3;

            [residency retireLease:placed_b_lease];
            [residency retireLease:committed_lease];
            placed_a = nil;
            placed_b = nil;
            committed = nil;
            placed_a_lease = nil;
            placed_b_lease = nil;
            committed_lease = nil;
        }
        if (![residency closePlacementHeap:&error])
        {
            printf("placement heap retirement failed: %s\n", error.localizedDescription.UTF8String);
            return 3;
        }

        /* --- pressure-aware LRU chunk cache ----------------------------- */
        AM12ResidencyBufferMaterializer materializer =
            ^uint64_t(id<MTLBuffer> buffer, uint32_t key) {
              return fill_chunk(buffer, key);
            };
        AM12ResidencyBufferChecksum checksum = ^uint64_t(id<MTLBuffer> buffer) {
          return sum_chunk(buffer);
        };

        for (uint32_t touch = 0; touch < CACHE_TOUCHES; touch++)
        {
            @autoreleasepool
            {
                uint32_t chunk = (uint32_t)random() % CACHE_WORKING_SET;
                id<MTLBuffer> buffer =
                    [residency touchCachedBufferForKey:chunk
                                                length:CHUNK_BYTES
                                               options:MTLResourceStorageModeShared
                                          materializer:materializer
                                              checksum:checksum
                                                 error:&error];
                if (!buffer)
                {
                    if (error.code == AM12ResidencyErrorChecksumMismatch)
                    {
                        AM12ResidencyCacheStats failed_stats = residency.cacheStats;
                        printf("eviction cache: %llu evictions, "
                               "%llu rematerializations verified, %llu mismatches\n",
                               (unsigned long long)failed_stats.eviction_count,
                               (unsigned long long)failed_stats.rematerialization_count,
                               (unsigned long long)failed_stats.mismatch_count);
                        return 5;
                    }
                    printf("cache allocation failed under normal pressure: %s\n",
                           error.localizedDescription.UTF8String);
                    return 4;
                }
            }
        }
        AM12ResidencyCacheStats cache_stats = residency.cacheStats;
        printf("eviction cache: %llu evictions, %llu rematerializations verified, "
               "%llu mismatches\n",
               (unsigned long long)cache_stats.eviction_count,
               (unsigned long long)cache_stats.rematerialization_count,
               (unsigned long long)cache_stats.mismatch_count);
        if (cache_stats.mismatch_count)
            return 5;
        [residency clearResidentCache];

        /* --- long-session churn ------------------------------------------ */
        uint64_t churn_start = drain(device);
        uint64_t peak = churn_start;
        NSMutableArray<AM12ResidencyLease *> *pool = [NSMutableArray array];
        uint64_t t0 = mach_absolute_time();

        for (uint32_t i = 0; i < CHURN_ITERATIONS; i++)
        {
            @autoreleasepool
            {
                if (pool.count > 96 || (pool.count && (random() & 1)))
                {
                    NSUInteger victim = (NSUInteger)random() % pool.count;
                    [residency retireLease:pool[victim]];
                    [pool removeObjectAtIndex:victim];
                }
                else
                {
                    size_t size = (size_t)(1 + random() % 16) << 20;
                    AM12ResidencyLease *lease =
                        [residency newCommittedBufferWithLength:size
                                                        options:MTLResourceStorageModeShared];
                    if (lease)
                    {
                        id<MTLBuffer> buf = (id<MTLBuffer>)lease.resource;
                        *(uint32_t *)buf.contents = i; /* touch first page */
                        [pool addObject:lease];
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
        for (AM12ResidencyLease *lease in pool)
            [residency retireLease:lease];
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

        if (!include_pressure)
        {
            puts("m12-004 residency safe checks ok");
            return 0;
        }

        /* --- guarded oversubscription push ------------------------------- */
        int bailed = 0;
        uint64_t push_base = drain(device);

        printf("oversubscription base after drain: %.1f MB\n", mb(push_base));

        for (;;)
        {
            @autoreleasepool
            {
                AM12ResidencyPressureDecision decision =
                    [residency pressureDecisionForCurrentAllocatedBytes:device.currentAllocatedSize
                                                   availableSystemBytes:available_memory()];
                if (decision == AM12ResidencyPressureDecisionReachedTarget)
                    break;
                if (decision == AM12ResidencyPressureDecisionBailOut)
                {
                    bailed = 1;
                    break;
                }

                id<MTLBuffer> buf =
                    [residency allocatePressureBufferWithLength:CHUNK_BYTES
                                                        options:MTLResourceStorageModeShared];
                if (!buf)
                    break;
                /* touch a quarter of the pages: enough commit to be real without
                 * swamping the machine */
                uint8_t *base = buf.contents;
                for (size_t off = 0; off < CHUNK_BYTES; off += PAGE_STRIDE * 4)
                    base[off] = (uint8_t)off;
            }
        }
        uint64_t at_peak = device.currentAllocatedSize;
        AM12ResidencyPressureStats pressure_stats = residency.pressureStats;
        [residency clearPressureAllocations];
        uint64_t settled = drain(device);
        printf("oversubscription: pushed %.0f MB to %.0f MB allocated "
               "(budget %.0f), %llu alloc failures, %llu evict-retry recoveries, %s\n",
               mb(pressure_stats.successful_allocation_bytes), mb(at_peak),
               mb(budget.recommended_max_working_set_bytes),
               (unsigned long long)pressure_stats.allocation_failure_count,
               (unsigned long long)pressure_stats.evict_retry_recovery_count,
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

int AM12RunResidencySafeProof(void)
{
    return run_residency_proof(NO);
}

int AM12RunResidencyProof(void)
{
    return run_residency_proof(YES);
}
