/*
 * M12-001 descriptor/binding virtualization prototype.
 * Author: Tim Isaev
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
 * Provenance: ADR-0012 discipline model; see ../PROVENANCE.md.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

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

struct heap_slot
{
    uint32_t resource; /* index into resources, or UINT32_MAX */
    uint64_t generation;
};

struct page
{
    id<MTLBuffer> buffer;
    _Atomic int in_flight;
    int cached; /* currently owned by the table cache */
    uint32_t next_free;
};

struct table_cache
{
    int valid;
    uint32_t page_index;
    uint32_t offset, count;
    uint64_t generation_sum;
};

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
        NSMutableArray<id<MTLBuffer>> *resources = [NSMutableArray array];
        for (uint32_t i = 0; i < RESOURCE_COUNT; i++)
        {
            id<MTLBuffer> buf = [device newBufferWithLength:16
                                                    options:MTLResourceStorageModeShared];
            *(uint32_t *)buf.contents = i;
            [resources addObject:buf];
        }
        id<MTLBuffer> poison = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        *(uint32_t *)poison.contents = POISON_ID;

        /* virtual heap */
        static struct heap_slot heap[HEAP_SLOTS];
        uint64_t next_generation = 1;
        for (uint32_t i = 0; i < HEAP_SLOTS; i++)
            heap[i] = (struct heap_slot){UINT32_MAX, 0};

        /* page ring */
        static struct page pages[PAGE_COUNT];
        __block uint32_t free_head = 0;
        NSLock *pool_lock = [[NSLock alloc] init];
        dispatch_semaphore_t free_pages = dispatch_semaphore_create(0);
        for (uint32_t i = 0; i < PAGE_COUNT; i++)
        {
            pages[i].buffer = [device newBufferWithLength:PAGE_ENTRIES * sizeof(uint64_t)
                                                  options:MTLResourceStorageModeShared];
            atomic_store(&pages[i].in_flight, 0);
            pages[i].cached = 0;
            pages[i].next_free = i + 1 < PAGE_COUNT ? i + 1 : UINT32_MAX;
            dispatch_semaphore_signal(free_pages);
        }

        uint64_t stall_count = 0, cache_hits = 0, cache_misses = 0;
        static _Atomic int pages_out;
        static _Atomic int max_pages_out;
        __block struct table_cache cache = {0};

        /* metric A: raw descriptor-update cost (heap record writes) */
        uint64_t t0 = mach_absolute_time();
        for (uint32_t i = 0; i < 1000000; i++)
        {
            uint32_t slot = i % HEAP_SLOTS;
            heap[slot].resource = i % RESOURCE_COUNT;
            heap[slot].generation = next_generation++;
        }
        uint64_t t1 = mach_absolute_time();
        printf("descriptor update: %.1f ns/descriptor (1M heap writes)\n",
               (double)(t1 - t0) * timebase_ns() / 1e6);

        /* helper blocks */
        uint32_t (^alloc_page)(void) = ^uint32_t {
          if (dispatch_semaphore_wait(free_pages, DISPATCH_TIME_NOW))
          {
              /* pool empty: bounded-memory stall until a page retires */
              dispatch_semaphore_wait(free_pages, DISPATCH_TIME_FOREVER);
          }
          [pool_lock lock];
          uint32_t index = free_head;
          free_head = pages[index].next_free;
          [pool_lock unlock];
          return index;
        };
        void (^release_page)(uint32_t) = ^(uint32_t index) {
          [pool_lock lock];
          /* poison before returning: any stale consumer reads the sentinel */
          uint64_t poison_addr = poison.gpuAddress;
          uint64_t *entries = (uint64_t *)pages[index].buffer.contents;
          for (uint32_t e = 0; e < PAGE_ENTRIES; e++)
              entries[e] = poison_addr;
          pages[index].next_free = free_head;
          free_head = index;
          [pool_lock unlock];
          dispatch_semaphore_signal(free_pages);
        };

        __block uint64_t encode_ns_total = 0, encode_descriptors = 0;

        /* encode a table (offset,count) into a page, honoring the cache */
        uint32_t (^bind_table)(uint32_t, uint32_t, uint64_t *) =
            ^uint32_t(uint32_t offset, uint32_t count, uint64_t *stall_local) {
              uint64_t generation_sum = 0;
              for (uint32_t i = 0; i < count; i++)
                  generation_sum += heap[offset + i].generation;
              if (cache.valid && cache.offset == offset && cache.count == count &&
                  cache.generation_sum == generation_sum)
                  return cache.page_index;

              uint64_t e0 = mach_absolute_time();
              uint32_t index = alloc_page();
              uint64_t *entries = (uint64_t *)pages[index].buffer.contents;
              for (uint32_t i = 0; i < count; i++)
              {
                  uint32_t r = heap[offset + i].resource;
                  entries[i] = r == UINT32_MAX ? poison.gpuAddress : resources[r].gpuAddress;
              }
              encode_ns_total += (uint64_t)((mach_absolute_time() - e0) * timebase_ns());
              encode_descriptors += count;

              if (cache.valid && !atomic_load(&pages[cache.page_index].in_flight))
              {
                  pages[cache.page_index].cached = 0;
                  release_page(cache.page_index);
              }
              else if (cache.valid)
                  pages[cache.page_index].cached = 0; /* retire via completion */
              cache = (struct table_cache){1, index, offset, count, generation_sum};
              pages[index].cached = 1;
              (void)stall_local;
              return index;
            };

        /* metric B: detector sensitivity - deliberate early recycle must fail */
        {
            uint32_t offset = 0, count = 64;
            for (uint32_t i = 0; i < count; i++)
            {
                heap[i].resource = i;
                heap[i].generation = next_generation++;
            }
            uint32_t page_index = bind_table(offset, count, &stall_count);
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
            [enc setBuffer:pages[page_index].buffer offset:0 atIndex:0];
            [enc setBuffer:indices offset:0 atIndex:1];
            [enc setBuffer:out offset:0 atIndex:2];
            [enc setBytes:&count length:sizeof(count) atIndex:3];
            [enc setBuffer:scratch offset:0 atIndex:4];
            for (uint32_t i = 0; i < count; i++)
                [enc useResource:resources[heap[i].resource] usage:MTLResourceUsageRead];
            [enc useResource:poison usage:MTLResourceUsageRead];
            [enc dispatchThreads:MTLSizeMake(count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [enc endEncoding];

            /* VIOLATION on purpose: poison the page before the GPU runs */
            cache.valid = 0;
            pages[page_index].cached = 0;
            release_page(page_index);
            page_index = alloc_page(); /* reclaim so pool stays consistent */
            release_page(page_index);

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
                    uint32_t slot = random() % HEAP_SLOTS;
                    heap[slot].resource = random() % RESOURCE_COUNT;
                    heap[slot].generation = next_generation++;
                }
                for (int c = 0; c < 4; c++)
                {
                    uint32_t dst = random() % (HEAP_SLOTS - 64);
                    uint32_t src = random() % (HEAP_SLOTS - 64);
                    for (int i = 0; i < 64; i++)
                    {
                        heap[dst + i] = heap[src + i];
                        heap[dst + i].generation = next_generation++;
                    }
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
                    count = 32 + random() % (PAGE_ENTRIES - 32);
                    offset = random() % (HEAP_SLOTS - count);
                    last_offset = offset;
                    last_count = count;
                }

                uint64_t generation_sum = 0;
                for (uint32_t i = 0; i < count; i++)
                    generation_sum += heap[offset + i].generation;
                int was_hit = cache.valid && cache.offset == offset && cache.count == count &&
                              cache.generation_sum == generation_sum;
                uint32_t page_index = bind_table(offset, count, &stall_count);
                if (was_hit)
                    cache_hits++;
                else
                    cache_misses++;

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
                    idx[i] = random() % count;
                    uint32_t r = heap[offset + idx[i]].resource;
                    expected[i] = r == UINT32_MAX ? POISON_ID : r;
                }

                id<MTLBuffer> scratch = [device newBufferWithLength:probes * sizeof(uint32_t)
                                                            options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> cb = [queues[d & 1] commandBuffer];
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pipeline];
                [enc setBuffer:pages[page_index].buffer offset:0 atIndex:0];
                [enc setBuffer:indices offset:0 atIndex:1];
                [enc setBuffer:out offset:0 atIndex:2];
                [enc setBytes:&probes length:sizeof(probes) atIndex:3];
                [enc setBuffer:scratch offset:0 atIndex:4];
                for (uint32_t i = 0; i < count; i++)
                {
                    uint32_t r = heap[offset + i].resource;
                    [enc useResource:(r == UINT32_MAX ? poison : resources[r])
                               usage:MTLResourceUsageRead];
                }
                [enc useResource:poison usage:MTLResourceUsageRead];
                [enc dispatchThreads:MTLSizeMake(probes, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                [enc endEncoding];

                if (atomic_fetch_add(&pages[page_index].in_flight, 1) == 0)
                {
                    int now = atomic_fetch_add(&pages_out, 1) + 1;
                    int seen_max = atomic_load(&max_pages_out);
                    while (now > seen_max &&
                           !atomic_compare_exchange_weak(&max_pages_out, &seen_max, now))
                        ;
                }
                uint32_t retire_index = page_index;
                [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                  (void)done;
                  if (atomic_fetch_sub(&pages[retire_index].in_flight, 1) == 1)
                  {
                      atomic_fetch_sub(&pages_out, 1);
                      if (!pages[retire_index].cached)
                          release_page(retire_index);
                  }
                }];
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

        printf("randomized model: %llu probes verified, %llu mismatches\n",
               (unsigned long long)verified, (unsigned long long)mismatches);
        printf("page encode: %.1f ns/descriptor (%llu descriptors)\n",
               encode_descriptors ? (double)encode_ns_total / encode_descriptors : 0.0,
               (unsigned long long)encode_descriptors);
        printf("table cache: %llu hits / %llu misses (%.1f%% hit on repeat-bind mix)\n",
               (unsigned long long)cache_hits, (unsigned long long)cache_misses,
               100.0 * cache_hits / (cache_hits + cache_misses));
        printf("page pool: %d pages, high-water in-flight %d, stalls %llu\n", PAGE_COUNT,
               atomic_load(&max_pages_out), (unsigned long long)stall_count);
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
