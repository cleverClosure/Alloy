/*
 * CPU-001 repeated multi-worker caught-AV stress.
 * Author: Tim Isaev
 *
 * seh_multi (result 11) sweeps the concurrency SHAPE but each worker faults
 * exactly once. Real titles are the other axis: a background thread that
 * catches a hardware fault does so over and over for the life of the process
 * (copy-protection probes, managed-runtime null-refs, per-thread guard-page
 * tricks). Issue #6 requires "2+ worker threads catching AVs repeatedly", so
 * this test holds the shape fixed and sweeps the REPETITION axis instead:
 *
 *   mode hammer     : all workers loop on their own AV concurrently
 *   mode sequential : one worker faults at a time, round-robin, ITERS rounds,
 *                     all workers alive throughout
 *   mode churn      : worker threads are created and joined repeatedly, each
 *                     catching a few AVs before exiting - exercises the
 *                     ThreadInit/ThreadTerm lifecycle against dispatch
 *
 * Every catch is counted; a healthy runtime yields exactly WORKERS*ITERS.
 * Exit 0 = every expected AV was caught; exit 21 = catches were lost (count
 * reported); exit 9 = watchdog stall.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <string.h>
#include <windows.h>

#define WORKERS 4
#define ITERS 200
#define CHURN_ROUNDS 40
#define CHURN_PER_THREAD 5

static HANDLE go_event;
static volatile LONG caught;
static volatile LONG seq_turn;

/* Kept noinline so the __try scope survives -O2: an inlined guarded body can
 * lose its .xdata scope entry entirely (result 10, cause 1). */
__attribute__((noinline)) static int catch_null_write(int payload)
{
    __try
    {
        volatile int *null_ptr = NULL;
        *null_ptr = payload;
        return 0;
    }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER
                                                               : EXCEPTION_CONTINUE_SEARCH)
    {
        return 1;
    }
}

__attribute__((noinline)) static int catch_null_read(int *sink)
{
    __try
    {
        volatile int *null_ptr = NULL;
        *sink = *null_ptr;
        return 0;
    }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER
                                                               : EXCEPTION_CONTINUE_SEARCH)
    {
        return 1;
    }
}

/* Alternate write/read faults so dispatch cannot settle into a single cached
 * path; both are guest AVs but reach the handler with different fault info. */
static int catch_one(int idx, int iter)
{
    int sink = 0;

    if ((iter & 1) == 0)
        return catch_null_write(idx + 1);
    return catch_null_read(&sink);
}

static DWORD WINAPI hammer_worker(LPVOID arg)
{
    int idx = (int)(INT_PTR)arg;
    int i;

    WaitForSingleObject(go_event, INFINITE);
    for (i = 0; i < ITERS; i++)
        if (catch_one(idx, i))
            InterlockedIncrement(&caught);
    return 0;
}

static DWORD WINAPI seq_worker(LPVOID arg)
{
    int idx = (int)(INT_PTR)arg;
    int i;

    for (i = 0; i < ITERS; i++)
    {
        while ((seq_turn % WORKERS) != idx)
            Sleep(0);
        if (catch_one(idx, i))
            InterlockedIncrement(&caught);
        InterlockedIncrement(&seq_turn);
    }
    return 0;
}

static DWORD WINAPI churn_worker(LPVOID arg)
{
    int idx = (int)(INT_PTR)arg;
    int i;

    for (i = 0; i < CHURN_PER_THREAD; i++)
        if (catch_one(idx, i))
            InterlockedIncrement(&caught);
    return 0;
}

static DWORD WINAPI watchdog(LPVOID arg)
{
    Sleep(120000);
    printf("%s: STALL (>120s), %ld caught\n", (const char *)arg, (long)caught);
    ExitProcess(9);
}

static int join_all(HANDLE *workers, int n)
{
    int i;

    WaitForMultipleObjects(n, workers, TRUE, INFINITE);
    for (i = 0; i < n; i++)
        CloseHandle(workers[i]);
    return 0;
}

static int run_hammer(void)
{
    HANDLE workers[WORKERS];
    int i;

    go_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    for (i = 0; i < WORKERS; i++)
        workers[i] = CreateThread(NULL, 0, hammer_worker, (LPVOID)(INT_PTR)i, 0, NULL);
    SetEvent(go_event);
    join_all(workers, WORKERS);
    CloseHandle(go_event);
    return WORKERS * ITERS;
}

static int run_sequential(void)
{
    HANDLE workers[WORKERS];
    int i;

    seq_turn = 0;
    for (i = 0; i < WORKERS; i++)
        workers[i] = CreateThread(NULL, 0, seq_worker, (LPVOID)(INT_PTR)i, 0, NULL);
    join_all(workers, WORKERS);
    return WORKERS * ITERS;
}

/* Each round spawns a fresh set of workers that fault a few times and exit, so
 * dispatch repeatedly meets thread states that were created after the first
 * exception was already dispatched on a sibling. */
static int run_churn(void)
{
    HANDLE workers[WORKERS];
    int round, i;

    for (round = 0; round < CHURN_ROUNDS; round++)
    {
        for (i = 0; i < WORKERS; i++)
            workers[i] = CreateThread(NULL, 0, churn_worker, (LPVOID)(INT_PTR)i, 0, NULL);
        join_all(workers, WORKERS);
    }
    return CHURN_ROUNDS * WORKERS * CHURN_PER_THREAD;
}

int main(int argc, char **argv)
{
    const char *mode = argc == 2 ? argv[1] : "hammer";
    int expected;

    setvbuf(stdout, NULL, _IONBF, 0);
    CreateThread(NULL, 0, watchdog, (LPVOID)mode, 0, NULL);

    caught = 0;
    if (strcmp(mode, "sequential") == 0)
        expected = run_sequential();
    else if (strcmp(mode, "churn") == 0)
        expected = run_churn();
    else
        expected = run_hammer();

    printf("%s: %ld/%d caught\n", mode, (long)caught, expected);
    if (caught != expected)
        return 21;
    printf("cpu-001 seh repeat (%s) ok\n", mode);
    return 0;
}
