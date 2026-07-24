/*
 * CPU-001 x64 atomic and memory-ordering smoke test.
 * Author: Timur Isaev
 */

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <windows.h>

enum
{
    WORKER_COUNT = 4,
    INCREMENTS_PER_WORKER = 250000,
    MESSAGE_ITERATIONS = 200000
};

struct aligned_pair
{
    uint64_t low;
    uint64_t high;
} __attribute__((aligned(16)));

struct message_state
{
    volatile LONG data;
    volatile LONG sequence;
    volatile LONG acknowledged;
    volatile LONG failure;
};

static volatile LONG increment_counter;
static volatile LONG64 cas_counter;
static struct message_state message;

static DWORD WINAPI increment_worker(void *parameter)
{
    unsigned int i;

    (void)parameter;
    for (i = 0; i < INCREMENTS_PER_WORKER; i++)
        InterlockedIncrement(&increment_counter);
    return 0;
}

static DWORD WINAPI cas_worker(void *parameter)
{
    unsigned int i;

    (void)parameter;
    for (i = 0; i < INCREMENTS_PER_WORKER; i++)
    {
        LONG64 observed;

        do
        {
            observed = cas_counter;
        } while (InterlockedCompareExchange64(&cas_counter, observed + 1, observed) != observed);
    }
    return 0;
}

static DWORD WINAPI message_writer(void *parameter)
{
    LONG i;

    (void)parameter;
    for (i = 1; i <= MESSAGE_ITERATIONS; i++)
    {
        while (message.acknowledged != i - 1)
            YieldProcessor();

        message.data = i;
        __asm__ volatile("" ::: "memory");
        message.sequence = i;
    }
    return 0;
}

static DWORD WINAPI message_reader(void *parameter)
{
    LONG i;

    (void)parameter;
    for (i = 1; i <= MESSAGE_ITERATIONS; i++)
    {
        LONG value;

        while (message.sequence != i)
            YieldProcessor();

        __asm__ volatile("" ::: "memory");
        value = message.data;
        if (value != i)
            InterlockedCompareExchange(&message.failure, i, 0);
        message.acknowledged = i;
    }
    return 0;
}

static int wait_for_threads(HANDLE *threads, unsigned int count)
{
    DWORD result = WaitForMultipleObjects(count, threads, TRUE, 30000);
    unsigned int i;

    if (result != WAIT_OBJECT_0)
        return 0;
    for (i = 0; i < count; i++)
        CloseHandle(threads[i]);
    return 1;
}

static int run_workers(LPTHREAD_START_ROUTINE routine)
{
    HANDLE threads[WORKER_COUNT];
    unsigned int i;

    for (i = 0; i < WORKER_COUNT; i++)
    {
        threads[i] = CreateThread(NULL, 0, routine, NULL, 0, NULL);
        if (!threads[i])
        {
            while (i)
                CloseHandle(threads[--i]);
            return 0;
        }
    }
    return wait_for_threads(threads, WORKER_COUNT);
}

static int compare_exchange_128(volatile struct aligned_pair *pair, uint64_t *expected_low,
                                uint64_t *expected_high, uint64_t desired_low,
                                uint64_t desired_high)
{
    unsigned char success;
    uint64_t low = *expected_low;
    uint64_t high = *expected_high;

    __asm__ volatile("lock cmpxchg16b %1\n\t"
                     "sete %0"
                     : "=q"(success), "+m"(*pair), "+a"(low), "+d"(high)
                     : "b"(desired_low), "c"(desired_high)
                     : "cc", "memory");
    *expected_low = low;
    *expected_high = high;
    return success;
}

static uint32_t locked_add_unaligned(volatile uint32_t *address, uint32_t addend)
{
    uint32_t previous = addend;

    __asm__ volatile("lock xaddl %0, %1" : "+r"(previous), "+m"(*address) : : "cc", "memory");
    return previous;
}

static int test_cmpxchg16b(void)
{
    volatile struct aligned_pair pair = {0x0123456789abcdefull, 0xfedcba9876543210ull};
    uint64_t expected_low = pair.low;
    uint64_t expected_high = pair.high;

    if (!compare_exchange_128(&pair, &expected_low, &expected_high, 0x1111222233334444ull,
                              0xaaaabbbbccccddddull))
        return 0;
    if (pair.low != 0x1111222233334444ull || pair.high != 0xaaaabbbbccccddddull)
        return 0;

    expected_low = 1;
    expected_high = 2;
    if (compare_exchange_128(&pair, &expected_low, &expected_high, 3, 4))
        return 0;
    return expected_low == pair.low && expected_high == pair.high;
}

static int test_unaligned_locked_operations(void)
{
    unsigned char *memory;
    volatile uint32_t *cache_line_crossing;
    volatile uint32_t *page_crossing;
    uint32_t previous;

    memory = VirtualAlloc(NULL, 0x3000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!memory)
        return 0;

    cache_line_crossing = (volatile uint32_t *)(memory + 63);
    page_crossing = (volatile uint32_t *)(memory + 0x0ffe);
    __builtin_memcpy((void *)cache_line_crossing, &(uint32_t){17}, sizeof(uint32_t));
    __builtin_memcpy((void *)page_crossing, &(uint32_t){29}, sizeof(uint32_t));

    previous = locked_add_unaligned(cache_line_crossing, 5);
    if (previous != 17 || *cache_line_crossing != 22)
    {
        VirtualFree(memory, 0, MEM_RELEASE);
        return 0;
    }

    previous = locked_add_unaligned(page_crossing, 7);
    if (previous != 29 || *page_crossing != 36)
    {
        VirtualFree(memory, 0, MEM_RELEASE);
        return 0;
    }

    VirtualFree(memory, 0, MEM_RELEASE);
    return 1;
}

static int test_message_ordering(void)
{
    HANDLE threads[2];

    message.data = 0;
    message.sequence = 0;
    message.acknowledged = 0;
    message.failure = 0;

    threads[0] = CreateThread(NULL, 0, message_writer, NULL, 0, NULL);
    threads[1] = CreateThread(NULL, 0, message_reader, NULL, 0, NULL);
    if (!threads[0] || !threads[1])
    {
        if (threads[0])
            CloseHandle(threads[0]);
        if (threads[1])
            CloseHandle(threads[1]);
        return 0;
    }

    return wait_for_threads(threads, 2) && !message.failure &&
           message.acknowledged == MESSAGE_ITERATIONS;
}

int main(void)
{
    const LONG64 expected_total = (LONG64)WORKER_COUNT * INCREMENTS_PER_WORKER;

    setvbuf(stdout, NULL, _IONBF, 0);

    increment_counter = 0;
    if (!run_workers(increment_worker))
        return 1;
    if (increment_counter != expected_total)
        return 2;
    printf("interlocked increment: %ld\n", increment_counter);

    cas_counter = 0;
    if (!run_workers(cas_worker))
        return 3;
    if (cas_counter != expected_total)
        return 4;
    printf("compare-exchange loop: %" PRId64 "\n", (int64_t)cas_counter);

    if (!test_cmpxchg16b())
        return 5;
    puts("cmpxchg16b: ok");

    if (!test_unaligned_locked_operations())
        return 6;
    puts("unaligned locked operations: cache-line and page crossing ok");

    if (!test_message_ordering())
        return 7;
    printf("store-order message passing: %d iterations ok\n", MESSAGE_ITERATIONS);

    puts("cpu-001 atomic/memory-ordering ok");
    return 0;
}
