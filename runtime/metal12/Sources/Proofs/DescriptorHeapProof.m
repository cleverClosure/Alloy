/*
 * M12-001 descriptor/binding virtualization runtime proof.
 * Author: Timur Isaev
 *
 * Models a D3D12 shader-visible descriptor heap on Metal 3 argument buffers:
 * the virtual heap is a CPU-side record array; binding a root table
 * materializes the referenced range into a fixed-size argument-buffer page
 * (an array of 64-bit GPU addresses) drawn from a recycling ring whose
 * retirement is driven by command-buffer completion across two queues.
 *
 * Verification: every resource is self-identifying (its first uint32 is its
 * id); a probe kernel dynamically indexes the bound page and reports the id
 * it actually read, and a CPU model predicts every probe result from the
 * heap contents at encode time.  Recycled pages are poisoned with a
 * dedicated sentinel resource, so any use-after-recycle diverges loudly.
 * A deliberate early-recycle pass proves the detector actually fires.
 *
 * Provenance: ADR-0012 discipline model; see ../../PROVENANCE.md.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "../Models/AM12DescriptorHeap.h"

#include <mach/mach.h>
#include <mach/mach_time.h>

#define HEAP_SLOTS 65536
#define RESOURCE_COUNT 1024
#define PAGE_ENTRIES 256
#define PAGE_COUNT 64
#define PROBE_THREADS 1024
#define ITERATIONS 300
#define DISPATCHES_PER_ITERATION 8
#define IN_FLIGHT_WINDOW 16
#define POISON_ID 0xDEADBEEFu

static const char *probe_source =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void probe(device const ulong *page [[buffer(0)]],\n"
    "                  device const uint *indices [[buffer(1)]],\n"
    "                  device uint *out [[buffer(2)]],\n"
    "                  device uint *scratch [[buffer(4)]],\n"
    "                  constant uint &count [[buffer(3)]],\n"
    "                  uint tid [[thread_position_in_grid]])\n"
    "{\n"
    "    if (tid >= count) return;\n"
    "    device const uint *res = (device const uint *)(page[indices[tid]]);\n"
    "    uint v = res[0];\n"
    "    for (int k = 0; k < 4000; k++)\n"
    "        v = v * 1664525u + 1013904223u;\n"
    "    scratch[tid] = v;\n"
    "    out[tid] = res[0];\n"
    "}\n";

struct pending
{
    id<MTLCommandBuffer> command_buffer;
    id<MTLBuffer> out;
    id<MTLBuffer> indices_buffer;
    uint32_t *expected;
    uint32_t count;
};

static double timebase_ns(void)
{
    static mach_timebase_info_data_t info;
    if (!info.denom)
        mach_timebase_info(&info);
    return (double)info.numer / info.denom;
}

static double resident_mb(void)
{
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) !=
        KERN_SUCCESS)
        return 0.0;
    return (double)info.resident_size / (1024.0 * 1024.0);
}

int AM12RunDescriptorHeapProof(void)
{
    @autoreleasepool
    {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            puts("no metal device");
            return 1;
        }
        printf("device: %s\n", device.name.UTF8String);

        NSError *error = nil;
        id<MTLLibrary> library =
            [device newLibraryWithSource:[NSString stringWithUTF8String:probe_source]
                                 options:nil
                                   error:&error];
        if (!library)
        {
            printf("library: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"probe"]
                                                  error:&error];
        if (!pipeline)
        {
            printf("pipeline: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }

        id<MTLCommandQueue> queues[2] = {[device newCommandQueue], [device newCommandQueue]};

        /* self-identifying resources + the poison sentinel */
        id<MTLBuffer> poison = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        if (!poison)
        {
            puts("poison resource creation failed");
            return 2;
        }
        *(uint32_t *)poison.contents = POISON_ID;

        AM12DescriptorHeapConfiguration heapConfiguration = {
            .slot_count = HEAP_SLOTS,
            .resource_capacity = RESOURCE_COUNT,
            .page_entry_count = PAGE_ENTRIES,
            .page_count = PAGE_COUNT,
            .invalid_resource_identifier = UINT32_MAX,
        };
        AM12DescriptorHeap *descriptorHeap =
            [[AM12DescriptorHeap alloc] initWithDevice:device
                                         configuration:heapConfiguration
                                          poisonBuffer:poison];
        if (!descriptorHeap)
        {
            puts("descriptor heap creation failed");
            return 2;
        }
        for (uint32_t resource = 0; resource < RESOURCE_COUNT; resource++)
        {
            id<MTLBuffer> buffer = [device newBufferWithLength:16
                                                       options:MTLResourceStorageModeShared];
            if (!buffer)
            {
                puts("descriptor resource creation failed");
                return 2;
            }
            *(uint32_t *)buffer.contents = resource;
            if (![descriptorHeap registerBuffer:buffer forResourceIdentifier:resource])
            {
                puts("descriptor resource registration failed");
                return 2;
            }
        }

        /* metric A: raw descriptor-update cost (heap record writes) */
        uint64_t t0 = mach_absolute_time();
        for (uint32_t i = 0; i < 1000000; i++)
        {
            uint32_t slot = i % HEAP_SLOTS;
            if (![descriptorHeap writeResourceIdentifier:i % RESOURCE_COUNT
                                                  atSlot:slot
                                              generation:nil])
            {
                puts("descriptor update failed");
                return 2;
            }
        }
        uint64_t t1 = mach_absolute_time();
        printf("descriptor update: %.1f ns/descriptor (1M heap writes)\n",
               (double)(t1 - t0) * timebase_ns() / 1e6);

        /* metric B: detector sensitivity - deliberate early recycle must fail */
        {
            uint32_t offset = 0, count = 64;
            for (uint32_t i = 0; i < count; i++)
            {
                if (![descriptorHeap writeResourceIdentifier:i atSlot:i generation:nil])
                {
                    puts("sensitivity descriptor update failed");
                    return 3;
                }
            }
            AM12DescriptorTable table;
            if (![descriptorHeap materializeTableAtOffset:offset count:count table:&table])
            {
                puts("sensitivity table materialization failed");
                return 3;
            }
            id<MTLBuffer> tableBuffer = [descriptorHeap bufferForTable:table];
            if (!tableBuffer)
            {
                puts("sensitivity table lookup failed");
                return 3;
            }
            id<MTLBuffer> indices = [device newBufferWithLength:count * sizeof(uint32_t)
                                                        options:MTLResourceStorageModeShared];
            id<MTLBuffer> out = [device newBufferWithLength:count * sizeof(uint32_t)
                                                    options:MTLResourceStorageModeShared];
            uint32_t *idx = (uint32_t *)indices.contents;
            for (uint32_t i = 0; i < count; i++)
                idx[i] = i;

            id<MTLBuffer> scratch = [device newBufferWithLength:count * sizeof(uint32_t)
                                                        options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [queues[0] commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pipeline];
            [enc setBuffer:tableBuffer offset:0 atIndex:0];
            [enc setBuffer:indices offset:0 atIndex:1];
            [enc setBuffer:out offset:0 atIndex:2];
            [enc setBytes:&count length:sizeof(count) atIndex:3];
            [enc setBuffer:scratch offset:0 atIndex:4];
            for (uint32_t i = 0; i < count; i++)
            {
                AM12HeapDescriptorRecord record;
                if (![descriptorHeap descriptorAtSlot:i record:&record])
                    return 3;
                id<MTLBuffer> resource =
                    [descriptorHeap bufferForResourceIdentifier:record.resource_identifier];
                if (!resource)
                    return 3;
                [enc useResource:resource usage:MTLResourceUsageRead];
            }
            [enc useResource:poison usage:MTLResourceUsageRead];
            [enc dispatchThreads:MTLSizeMake(count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc endEncoding];

            /* VIOLATION on purpose: poison the page before the GPU runs */
            if (![descriptorHeap forceRecycleTableImmediatelyForTesting:table])
            {
                puts("sensitivity forced recycle failed");
                return 3;
            }

            [cb commit];
            [cb waitUntilCompleted];
            uint32_t poisoned = 0;
            uint32_t *seen = (uint32_t *)out.contents;
            for (uint32_t i = 0; i < count; i++)
                if (seen[i] == POISON_ID)
                    poisoned++;
            printf("sensitivity: deliberate early recycle -> %u/%u poison reads %s\n", poisoned,
                   count, poisoned == count ? "(detector proven)" : "(DETECTOR BLIND)");
            if (poisoned != count)
                return 3;
        }
        AM12DescriptorHeapStatistics cacheBaseline = descriptorHeap.statistics;

        /* metric C: randomized model test, two queues, in-flight window */
        srandom(1234);
        static struct pending window[IN_FLIGHT_WINDOW];
        int window_head = 0, window_size = 0;
        __block uint64_t mismatches = 0, verified = 0;

        void (^drain_one)(int) = ^(int slot) {
          struct pending *p = &window[slot];
          [p->command_buffer waitUntilCompleted];
          uint32_t *seen = (uint32_t *)p->out.contents;
          for (uint32_t i = 0; i < p->count; i++)
              if (seen[i] != p->expected[i])
              {
                  if (mismatches < 5)
                      printf("  mismatch[%u]: expected %u seen 0x%x\n", i, p->expected[i], seen[i]);
                  mismatches++;
              }
          verified += p->count;
          free(p->expected);
          p->expected = NULL;
        };

        for (uint32_t iteration = 0; iteration < ITERATIONS; iteration++)
        {
            for (uint32_t d = 0; d < DISPATCHES_PER_ITERATION; d++)
            {
                /* random mutations: descriptor writes + copies */
                for (int m = 0; m < 32; m++)
                {
                    uint32_t slot = (uint32_t)random() % HEAP_SLOTS;
                    uint32_t resource = (uint32_t)random() % RESOURCE_COUNT;
                    if (![descriptorHeap writeResourceIdentifier:resource
                                                          atSlot:slot
                                                      generation:nil])
                        return 4;
                }
                for (int c = 0; c < 4; c++)
                {
                    uint32_t dst = (uint32_t)random() % (HEAP_SLOTS - 64);
                    uint32_t src = (uint32_t)random() % (HEAP_SLOTS - 64);
                    if (![descriptorHeap copyDescriptorsFromSlot:src toSlot:dst count:64])
                        return 4;
                }

                /* random table, sometimes repeated to exercise the cache */
                static uint32_t last_offset = 0, last_count = 0;
                uint32_t offset, count;
                if (d && (random() % 4) == 0 && last_count)
                {
                    offset = last_offset;
                    count = last_count;
                }
                else
                {
                    count = 32u + (uint32_t)random() % (PAGE_ENTRIES - 32);
                    offset = (uint32_t)random() % (HEAP_SLOTS - count);
                    last_offset = offset;
                    last_count = count;
                }

                AM12DescriptorTable table;
                if (![descriptorHeap materializeTableAtOffset:offset count:count table:&table])
                    return 4;
                id<MTLBuffer> tableBuffer = [descriptorHeap bufferForTable:table];
                if (!tableBuffer)
                    return 4;

                /* probe: random dynamic indices into the table */
                uint32_t probes = PROBE_THREADS < count ? PROBE_THREADS : count * 4;
                id<MTLBuffer> indices = [device newBufferWithLength:probes * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
                id<MTLBuffer> out = [device newBufferWithLength:probes * sizeof(uint32_t)
                                                        options:MTLResourceStorageModeShared];
                uint32_t *idx = (uint32_t *)indices.contents;
                uint32_t *expected = malloc(probes * sizeof(uint32_t));
                for (uint32_t i = 0; i < probes; i++)
                {
                    idx[i] = (uint32_t)random() % count;
                    AM12HeapDescriptorRecord record;
                    if (![descriptorHeap descriptorAtSlot:offset + idx[i] record:&record])
                        return 4;
                    expected[i] = record.resource_identifier == UINT32_MAX
                                      ? POISON_ID
                                      : record.resource_identifier;
                }

                id<MTLBuffer> scratch = [device newBufferWithLength:probes * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [queues[d & 1] commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pipeline];
                [enc setBuffer:tableBuffer offset:0 atIndex:0];
                [enc setBuffer:indices offset:0 atIndex:1];
                [enc setBuffer:out offset:0 atIndex:2];
                [enc setBytes:&probes length:sizeof(probes) atIndex:3];
                [enc setBuffer:scratch offset:0 atIndex:4];
                for (uint32_t i = 0; i < count; i++)
                {
                    AM12HeapDescriptorRecord record;
                    if (![descriptorHeap descriptorAtSlot:offset + i record:&record])
                        return 4;
                    id<MTLBuffer> resource =
                        [descriptorHeap bufferForResourceIdentifier:record.resource_identifier];
                    if (!resource)
                        return 4;
                    [enc useResource:resource usage:MTLResourceUsageRead];
                }
                [enc useResource:poison usage:MTLResourceUsageRead];
                [enc dispatchThreads:MTLSizeMake(probes, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                [enc endEncoding];

                if (![descriptorHeap retainTable:table untilCommandBufferCompletes:cb])
                    return 4;
                [cb commit];

                if (window_size == IN_FLIGHT_WINDOW)
                {
                    drain_one(window_head);
                    window_head = (window_head + 1) % IN_FLIGHT_WINDOW;
                    window_size--;
                }
                window[(window_head + window_size) % IN_FLIGHT_WINDOW] =
                    (struct pending){cb, out, indices, expected, probes};
                window_size++;
            }
        }
        while (window_size)
        {
            drain_one(window_head);
            window_head = (window_head + 1) % IN_FLIGHT_WINDOW;
            window_size--;
        }

        AM12DescriptorHeapStatistics stats = descriptorHeap.statistics;
        uint64_t cacheHits = stats.cache_hits - cacheBaseline.cache_hits;
        uint64_t cacheMisses = stats.cache_misses - cacheBaseline.cache_misses;
        printf("randomized model: %llu probes verified, %llu mismatches\n",
               (unsigned long long)verified, (unsigned long long)mismatches);
        printf("page encode: %.1f ns/descriptor (%llu descriptors)\n",
               stats.encoded_descriptors
                   ? (double)stats.encode_nanoseconds / (double)stats.encoded_descriptors
                   : 0.0,
               (unsigned long long)stats.encoded_descriptors);
        printf("table cache: %llu hits / %llu misses (%.1f%% hit on repeat-bind mix)\n",
               (unsigned long long)cacheHits, (unsigned long long)cacheMisses,
               100.0 * (double)cacheHits / (double)(cacheHits + cacheMisses));
        printf("page pool: %d pages, high-water in-flight %u, stalls %llu\n", PAGE_COUNT,
               stats.max_pages_in_flight, (unsigned long long)stats.page_stalls);
        printf("resident memory: %.1f MB\n", resident_mb());

        if (mismatches)
        {
            puts("m12-001 FAILED");
            return 4;
        }
        puts("m12-001 descriptor virtualization ok");
        return 0;
    }
}
