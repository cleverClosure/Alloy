/*
 * CPU-001 multi-thread caught-AV severity characterizer.
 * Author: Tim Isaev
 *
 * seh_concurrent proved that N threads faulting at the SAME INSTANT (behind
 * one event) corrupt dispatch (only 1/N catch). That is a pathological
 * pattern - real games catch hardware faults with sibling threads ALIVE but
 * not synchronised to the same cycle. This test sweeps the concurrency shape
 * to locate the boundary between "works" and "corrupts":
 *
 *   mode simultaneous : all workers released by one event (== seh_concurrent)
 *   mode staggered    : worker i waits i*STAGGER_MS after release
 *   mode sequential   : workers run one at a time, each joined before the next,
 *                       while all other workers already exist (alive, idle)
 *
 * Every worker catches its own null-write AV. A healthy runtime yields
 * WORKERS catches in every mode. Exit 0 = this mode fully caught;
 * exit 20+missed = this mode lost (20 + number of missed catches, capped);
 * exit 9 = watchdog stall.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <string.h>
#include <windows.h>

#define WORKERS 4
#define STAGGER_MS 15

static HANDLE go_event;
static volatile LONG caught;
static volatile LONG stagger_ms;

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

static DWORD WINAPI av_worker(LPVOID arg)
{
    int idx = (int)(INT_PTR)arg;

    if (go_event)
        WaitForSingleObject(go_event, INFINITE);
    if (stagger_ms)
        Sleep(idx * stagger_ms);
    if (catch_null_write(idx + 1))
        InterlockedIncrement(&caught);
    return 0;
}

static DWORD WINAPI watchdog(LPVOID arg)
{
    (void)arg;
    Sleep(25000);
    printf("%s: STALL (>25s), %ld/%d caught\n", (const char *)arg, (long)caught, WORKERS);
    ExitProcess(9);
}

static int run_released(const char *mode, int stagger)
{
    HANDLE workers[WORKERS];
    int i;

    caught = 0;
    stagger_ms = stagger;
    go_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    for (i = 0; i < WORKERS; i++)
        workers[i] = CreateThread(NULL, 0, av_worker, (LPVOID)(INT_PTR)i, 0, NULL);
    SetEvent(go_event);
    WaitForMultipleObjects(WORKERS, workers, TRUE, INFINITE);
    for (i = 0; i < WORKERS; i++)
        CloseHandle(workers[i]);
    CloseHandle(go_event);
    go_event = NULL;
    printf("%s: %ld/%d caught\n", mode, (long)caught, WORKERS);
    return caught == WORKERS ? 0 : 20 + (WORKERS - (int)caught);
}

/* sequential: spawn all workers up front (so siblings exist and are alive),
 * but gate them so exactly one faults at a time, joined before the next */
static volatile LONG seq_turn;

static DWORD WINAPI seq_worker(LPVOID arg)
{
    int idx = (int)(INT_PTR)arg;

    while (seq_turn != idx)
        Sleep(1);
    if (catch_null_write(idx + 1))
        InterlockedIncrement(&caught);
    InterlockedIncrement(&seq_turn);
    return 0;
}

static int run_sequential(int warmup)
{
    HANDLE workers[WORKERS];
    int i;

    caught = 0;
    seq_turn = 0;
    /* warmup: the main thread catches its own AV first, to test whether a
     * successful main-thread dispatch inoculates subsequent worker dispatches */
    if (warmup)
        printf("warmup main catch: %s\n", catch_null_write(99) ? "caught" : "MISSED");
    for (i = 0; i < WORKERS; i++)
        workers[i] = CreateThread(NULL, 0, seq_worker, (LPVOID)(INT_PTR)i, 0, NULL);
    WaitForMultipleObjects(WORKERS, workers, TRUE, INFINITE);
    for (i = 0; i < WORKERS; i++)
        CloseHandle(workers[i]);
    printf("%s: %ld/%d caught\n", warmup ? "warmup-seq" : "sequential", (long)caught, WORKERS);
    return caught == WORKERS ? 0 : 20 + (WORKERS - (int)caught);
}

int main(int argc, char **argv)
{
    const char *mode = argc == 2 ? argv[1] : "simultaneous";
    int rc;

    setvbuf(stdout, NULL, _IONBF, 0);
    CreateThread(NULL, 0, watchdog, (LPVOID)mode, 0, NULL);

    if (strcmp(mode, "staggered") == 0)
        rc = run_released("staggered", STAGGER_MS);
    else if (strcmp(mode, "sequential") == 0)
        rc = run_sequential(0);
    else if (strcmp(mode, "warmup") == 0)
        rc = run_sequential(1);
    else
        rc = run_released("simultaneous", 0);

    if (rc == 0)
        printf("cpu-001 seh multi (%s) ok\n", mode);
    return rc;
}
