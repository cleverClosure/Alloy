/* Portable atomics: serial reference and contended invariants. Author: Timur Isaev */
#include "isa_corpus_common.h"
#include <stdatomic.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif

enum
{
    CAS_OK,
    CAS_MISS,
    XADD,
    EXCHANGE,
    FETCH_OR,
    FETCH_AND,
    FETCH_XOR
};
typedef struct
{
    const char *name;
    unsigned code, bits;
} atomic_op;
typedef struct
{
    uint64_t observed, final, expected;
    unsigned success;
} atomic_result;
#define BOTH(name, code) {name "32", code, 32}, {name "64", code, 64}
static const atomic_op ops[] = {BOTH("cas-success", CAS_OK), BOTH("cas-failure", CAS_MISS),
                                BOTH("fetch-add", XADD),     BOTH("exchange", EXCHANGE),
                                BOTH("fetch-or", FETCH_OR),  BOTH("fetch-and", FETCH_AND),
                                BOTH("fetch-xor", FETCH_XOR)};
#undef BOTH

static CORPUS_REFERENCE atomic_result reference(const atomic_op *op, uint64_t a, uint64_t b)
{
    uint64_t mask = op->bits == 64 ? UINT64_MAX : UINT32_MAX;
    a &= mask;
    b &= mask;
    atomic_result r = {a, a, a, 0};
    switch (op->code)
    {
    case CAS_OK:
        r.final = b;
        r.success = 1;
        break;
    case CAS_MISS:
        break;
    case XADD:
        r.final = (a + b) & mask;
        break;
    case EXCHANGE:
        r.final = b;
        break;
    case FETCH_OR:
        r.final = a | b;
        break;
    case FETCH_AND:
        r.final = a & b;
        break;
    case FETCH_XOR:
        r.final = a ^ b;
        break;
    default:
        fputs("FAIL unknown atomic reference\n", stderr);
        exit(2);
    }
#ifdef ALLOY_CORPUS_MUTATE
    if (op == &ops[0])
        r.final ^= 1;
#endif
    return r;
}

/* This runs on both hosts. The arm64 half checks actual host atomic operations,
 * rather than echoing the serial reference as the hardware result. */
static CORPUS_INSTRUCTION atomic_result instruction(const atomic_op *op, uint64_t a, uint64_t b)
{
    atomic_result r = {0, 0, 0, 0};
#define OPERATIONS(type)                                                                           \
    do                                                                                             \
    {                                                                                              \
        _Atomic(type) location = (type)a;                                                          \
        type expected = (type)a, desired = (type)b;                                                \
        r.expected = (type)a;                                                                      \
        switch (op->code)                                                                          \
        {                                                                                          \
        case CAS_OK:                                                                               \
        case CAS_MISS:                                                                             \
            if (op->code == CAS_MISS)                                                              \
                expected ^= 1;                                                                     \
            r.success = atomic_compare_exchange_strong_explicit(                                   \
                &location, &expected, desired, memory_order_seq_cst, memory_order_seq_cst);        \
            r.observed = expected;                                                                 \
            r.expected = expected;                                                                 \
            break;                                                                                 \
        case XADD:                                                                                 \
            r.observed = atomic_fetch_add_explicit(&location, desired, memory_order_seq_cst);      \
            break;                                                                                 \
        case EXCHANGE:                                                                             \
            r.observed = atomic_exchange_explicit(&location, desired, memory_order_seq_cst);       \
            break;                                                                                 \
        case FETCH_OR:                                                                             \
            r.observed = atomic_fetch_or_explicit(&location, desired, memory_order_seq_cst);       \
            break;                                                                                 \
        case FETCH_AND:                                                                            \
            r.observed = atomic_fetch_and_explicit(&location, desired, memory_order_seq_cst);      \
            break;                                                                                 \
        case FETCH_XOR:                                                                            \
            r.observed = atomic_fetch_xor_explicit(&location, desired, memory_order_seq_cst);      \
            break;                                                                                 \
        default:                                                                                   \
            fputs("FAIL unknown atomic instruction\n", stderr);                                    \
            exit(2);                                                                               \
        }                                                                                          \
        r.final = atomic_load_explicit(&location, memory_order_seq_cst);                           \
    } while (0)
    if (op->bits == 32)
    {
        OPERATIONS(uint32_t);
    }
    else
    {
        OPERATIONS(uint64_t);
    }
#undef OPERATIONS
    return r;
}

static unsigned failures;
static void check(const atomic_op *op, atomic_result expected, atomic_result actual,
                  const char *where)
{
    if (expected.observed == actual.observed && expected.final == actual.final &&
        expected.expected == actual.expected && expected.success == actual.success)
        return;
    if (failures < 12)
        printf("FAIL %s %s expected=%016llx/%016llx/%016llx/%u actual=%016llx/%016llx/%016llx/%u\n",
               op->name, where, (unsigned long long)expected.observed,
               (unsigned long long)expected.final, (unsigned long long)expected.expected,
               expected.success, (unsigned long long)actual.observed,
               (unsigned long long)actual.final, (unsigned long long)actual.expected,
               actual.success);
    ++failures;
}

static void fold(uint64_t *hash, atomic_result r)
{
    corpus_fold(hash, &r.observed, 8);
    corpus_fold(hash, &r.final, 8);
    corpus_fold(hash, &r.expected, 8);
    corpus_fold(hash, &r.success, 4);
}

#define THREAD_COUNT 4
#define PER_THREAD 1024
#define TICKETS (THREAD_COUNT * PER_THREAD)
static _Atomic(uint64_t) ticket_counter, ticket_sum;
static _Atomic(unsigned) duplicate_tickets, ready, start;
static _Atomic(uint32_t) seen[TICKETS / 32];

#ifdef _WIN32
static DWORD WINAPI worker(void *unused)
#else
static void *worker(void *unused)
#endif
{
    (void)unused;
    atomic_fetch_add(&ready, 1);
    while (!atomic_load_explicit(&start, memory_order_acquire))
    {
    }
    for (unsigned i = 0; i < PER_THREAD; ++i)
    {
        uint64_t ticket = atomic_fetch_add_explicit(&ticket_counter, 1, memory_order_seq_cst);
#ifdef ALLOY_CORPUS_MUTATE_THREADS
        ticket %= TICKETS / 2;
#endif
        if (ticket >= TICKETS)
        {
            atomic_fetch_add(&duplicate_tickets, 1);
            continue;
        }
        uint32_t bit = UINT32_C(1) << (ticket % 32);
        if (atomic_fetch_or_explicit(&seen[ticket / 32], bit, memory_order_seq_cst) & bit)
            atomic_fetch_add(&duplicate_tickets, 1);
        atomic_fetch_add_explicit(&ticket_sum, ticket, memory_order_seq_cst);
    }
    return 0;
}

static uint64_t run_threads(void)
{
#ifdef _WIN32
    HANDLE threads[THREAD_COUNT];
    for (unsigned i = 0; i < THREAD_COUNT; ++i)
    {
        threads[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (!threads[i])
        {
            fputs("FAIL CreateThread\n", stderr);
            exit(2);
        }
    }
#else
    pthread_t threads[THREAD_COUNT];
    for (unsigned i = 0; i < THREAD_COUNT; ++i)
        if (pthread_create(&threads[i], NULL, worker, NULL) != 0)
        {
            fputs("FAIL pthread_create\n", stderr);
            exit(2);
        }
#endif
    while (atomic_load(&ready) != THREAD_COUNT)
    {
    }
    atomic_store_explicit(&start, 1, memory_order_release);
    for (unsigned i = 0; i < THREAD_COUNT; ++i)
    {
#ifdef _WIN32
        if (WaitForSingleObject(threads[i], 10000) != WAIT_OBJECT_0)
        {
            fputs("FAIL worker timeout\n", stderr);
            exit(2);
        }
        CloseHandle(threads[i]);
#else
        if (pthread_join(threads[i], NULL) != 0)
        {
            fputs("FAIL pthread_join\n", stderr);
            exit(2);
        }
#endif
    }
    uint64_t count = atomic_load(&ticket_counter), sum = atomic_load(&ticket_sum);
    uint64_t hash = CORPUS_FNV_OFFSET;
    int broken = count != TICKETS || sum != (uint64_t)TICKETS * (TICKETS - 1) / 2 ||
                 atomic_load(&duplicate_tickets) != 0;
    corpus_fold(&hash, &count, 8);
    corpus_fold(&hash, &sum, 8);
    for (unsigned i = 0; i < TICKETS / 32; ++i)
    {
        uint32_t value = atomic_load(&seen[i]);
        broken |= value != UINT32_MAX;
        corpus_fold(&hash, &value, 4);
    }
    if (broken)
    {
        printf("FAIL tickets invariant count=%llu sum=%llu duplicates=%u\n",
               (unsigned long long)count, (unsigned long long)sum, atomic_load(&duplicate_tickets));
        ++failures;
    }
    return hash;
}

int main(void)
{
    static const uint64_t edge[] = {0,
                                    1,
                                    2,
                                    15,
                                    16,
                                    31,
                                    32,
                                    UINT32_MAX,
                                    UINT64_MAX,
                                    UINT64_C(0x80000000),
                                    UINT64_C(0x7fffffff),
                                    UINT64_C(0x8000000000000000),
                                    UINT64_C(0x7fffffffffffffff),
                                    UINT64_C(0xaaaaaaaa55555555)};
    const unsigned edges = sizeof edge / sizeof edge[0], total = edges * edges + 2048;
#ifdef ALLOY_CORPUS_MUTATE
    const char *mutation = ops[0].name;
#elif defined(ALLOY_CORPUS_MUTATE_THREADS)
    const char *mutation = "tickets";
#else
    const char *mutation = "none";
#endif
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("cpu-001 isa-corpus atomics mode=%s seed=%016llx mutate=%s\n",
           CORPUS_X86 ? "instruction-parity" : "native-parity", (unsigned long long)CORPUS_SEED,
           mutation);
    atomic_result literal = {7, 11, 7, 1};
    check(&ops[0], literal, reference(&ops[0], 7, 11), "hand-vector");
    uint64_t family_hash = CORPUS_FNV_OFFSET;
    for (unsigned o = 0; o < sizeof ops / sizeof ops[0]; ++o)
    {
        uint64_t state = CORPUS_SEED, hash = CORPUS_FNV_OFFSET;
        for (unsigned i = 0; i < total; ++i)
        {
            uint64_t a = i < edges * edges ? edge[i / edges] : corpus_random(&state);
            uint64_t b = i < edges * edges ? edge[i % edges] : corpus_random(&state);
            atomic_result expected = reference(&ops[o], a, b);
            check(&ops[o], expected, instruction(&ops[o], a, b), "parity");
            fold(&hash, expected);
            fold(&family_hash, expected);
        }
        printf("op=%s cases=%u checksum=%016llx\n", ops[o].name, total, (unsigned long long)hash);
    }
    uint64_t thread_hash = run_threads();
    corpus_fold(&family_hash, &thread_hash, 8);
    printf("op=tickets cases=%u checksum=%016llx\n", TICKETS, (unsigned long long)thread_hash);
    printf("cpu-001 isa-corpus atomics: cases=%u failures=%u checksum=%016llx mutate=%s\n",
           total * (unsigned)(sizeof ops / sizeof ops[0]) + TICKETS, failures,
           (unsigned long long)family_hash, mutation);
    return failures ? 1 : 0;
}
