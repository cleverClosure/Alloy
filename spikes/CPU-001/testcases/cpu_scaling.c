/*
 * CPU-001 multi-thread compute-scaling benchmark.
 * Author: Tim Isaev
 *
 * Result 14 measured single-thread throughput. Games run worker-thread pools,
 * so what matters next is whether FEX's translation scales across cores or
 * serializes on hidden per-process state (a shared code-cache lock, JIT
 * serialization). This runs a contention-free pure-ALU kernel (xorshift mix,
 * no shared memory) across 1/2/4/8 threads and reports aggregate throughput
 * and parallel efficiency. The SAME source builds as an x64 PE (under FEX) and
 * native arm64; comparing the two scaling curves isolates any FEX-specific
 * serialization. Exit 0 iff every batch completed with a non-zero checksum.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef HANDLE thread_t;
static uint64_t now_ns(void)
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (uint64_t)c.QuadPart * 1000000000ull / (uint64_t)f.QuadPart;
}
static const char *host_tag = "x86_64-PE-under-FEX";
#else
#include <pthread.h>
#include <time.h>
typedef pthread_t thread_t;
static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}
static const char *host_tag = "native";
#endif

#define ITERS_PER_THREAD 200000000ull
#define MAX_THREADS 8

static uint64_t kernel_int(uint64_t n, uint64_t seed)
{
    uint64_t x = seed | 1;
    for (uint64_t i = 0; i < n; i++)
    {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x *= 0x2545F4914F6CDD1Dull;
    }
    return x;
}

struct work
{
    uint64_t seed;
    uint64_t result;
};

#if defined(_WIN32)
static DWORD WINAPI worker(LPVOID arg)
#else
static void *worker(void *arg)
#endif
{
    struct work *w = (struct work *)arg;
    w->result = kernel_int(ITERS_PER_THREAD, w->seed);
#if defined(_WIN32)
    return 0;
#else
    return NULL;
#endif
}

static uint64_t run_n(int n, uint64_t *checksum)
{
    struct work works[MAX_THREADS];
    thread_t threads[MAX_THREADS];
    int i;
    uint64_t t0, t1, chk = 0;

    for (i = 0; i < n; i++)
        works[i].seed = 0x9E3779B97F4A7C15ull + (uint64_t)i * 0x1000193ull;

    t0 = now_ns();
    for (i = 0; i < n; i++)
    {
#if defined(_WIN32)
        threads[i] = CreateThread(NULL, 0, worker, &works[i], 0, NULL);
#else
        pthread_create(&threads[i], NULL, worker, &works[i]);
#endif
    }
    for (i = 0; i < n; i++)
    {
#if defined(_WIN32)
        WaitForSingleObject(threads[i], INFINITE);
        CloseHandle(threads[i]);
#else
        pthread_join(threads[i], NULL);
#endif
        chk ^= works[i].result;
    }
    t1 = now_ns();
    *checksum = chk;
    return t1 - t0;
}

int main(void)
{
    const int counts[] = {1, 2, 4, 8};
    const int nc = (int)(sizeof counts / sizeof counts[0]);
    uint64_t base_tput = 0, guard = 0;
    int i;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("cpu-001 scaling [%s]  %llu iters/thread\n", host_tag,
           (unsigned long long)ITERS_PER_THREAD);

    for (i = 0; i < nc; i++)
    {
        int n = counts[i];
        uint64_t chk = 0;
        uint64_t ns = run_n(n, &chk);
        uint64_t total_ops = (uint64_t)n * ITERS_PER_THREAD;
        double tput = (double)total_ops / (double)ns; /* ops per ns == Gops/s */
        if (i == 0)
            base_tput = (uint64_t)(tput * 1e6);
        double eff = tput / ((double)n * (double)base_tput / 1e6);
        guard ^= chk;
        printf("%d thread%s  %7.3f ms  %6.2f Gops/s  scale %4.2fx  eff %5.1f%%  chk=%016llx\n", n,
               n == 1 ? " " : "s", (double)ns / 1e6, tput, tput * 1e6 / (double)base_tput,
               eff * 100.0, (unsigned long long)chk);
        if (chk == 0)
            return 2 + i;
    }
    printf("guard=%016llx\n", (unsigned long long)guard);
    return guard ? 0 : 1;
}
