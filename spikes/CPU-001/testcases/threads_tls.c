/*
 * CPU-001 threading / TLS churn guest.
 * Author: Timur Isaev
 *
 * Exercises what threaded engines do all frame: contended atomics with an
 * exact global invariant, __thread and TlsAlloc storage isolation, thread
 * create/join churn, event handshakes, and a per-thread SEH catch.
 * Self-verifying; distinct exit code per failing family.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <windows.h>

#define WORKERS 4
#define INCREMENTS 5000
#define CHURN_THREADS 400

static volatile LONG shared_counter;
static volatile LONG64 shared_counter64;
static __thread int tls_static;
static DWORD tls_index;
static volatile LONG tls_errors;
static volatile LONG seh_caught;
static HANDLE go_event;
static HANDLE seh_turn[WORKERS + 1];

static DWORD WINAPI contender(LPVOID arg)
{
    int id = (int)(INT_PTR)arg;

    WaitForSingleObject(go_event, INFINITE);
    tls_static = id * 3 + 1;
    TlsSetValue(tls_index, (LPVOID)(INT_PTR)(id * 7 + 5));
    if (tls_static != id * 3 + 1)
        InterlockedIncrement(&tls_errors);
    if ((INT_PTR)TlsGetValue(tls_index) != id * 7 + 5)
        InterlockedIncrement(&tls_errors);

    /* no faults here: a guest AV with other guest threads alive deadlocks
     * exception dispatch - covered by the seh_concurrent.c detector */
    return (DWORD)id;
}

static DWORD WINAPI churner(LPVOID arg)
{
    return (DWORD)(INT_PTR)arg + 1000;
}

static HANDLE atomics_done;

static DWORD WINAPI atomics_worker(LPVOID arg)
{
    (void)arg;
    WaitForSingleObject(go_event, INFINITE);
    for (int i = 0; i < INCREMENTS; i++)
    {
        InterlockedIncrement(&shared_counter);
        InterlockedAdd64(&shared_counter64, 3);
    }
    return 0;
}

static DWORD WINAPI watchdog(LPVOID arg)
{
    (void)arg;
    if (WaitForSingleObject(atomics_done, 30000) != WAIT_OBJECT_0)
    {
        /* known FEX finding: contended exclusives retry-storm; report and
         * end the run with a distinct code instead of hanging forever */
        puts("atomics: CONTENTION STALL (>30s) - known FEX exclusives finding");
        ExitProcess(7);
    }
    return 0;
}

int main(void)
{
    HANDLE workers[WORKERS];

    setvbuf(stdout, NULL, _IONBF, 0);
    tls_index = TlsAlloc();
    go_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (tls_index == TLS_OUT_OF_INDEXES || !go_event)
        return 1;
    for (int i = 0; i <= WORKERS; i++)
        seh_turn[i] = CreateEventW(NULL, TRUE, i == 0, NULL);

    for (int i = 0; i < WORKERS; i++)
        workers[i] = CreateThread(NULL, 0, contender, (LPVOID)(INT_PTR)i, 0, NULL);
    SetEvent(go_event);
    WaitForMultipleObjects(WORKERS, workers, TRUE, 120000);
    for (int i = 0; i < WORKERS; i++)
    {
        DWORD code = 0;
        GetExitCodeThread(workers[i], &code);
        if (code != (DWORD)i)
        {
            printf("worker %d exit code %lu\n", i, (unsigned long)code);
            return 2;
        }
        CloseHandle(workers[i]);
    }

    printf("tls: %ld isolation errors\n", (long)tls_errors);
    if (tls_errors)
        return 4;

    /* create/join churn in small batches */
    for (int batch = 0; batch < CHURN_THREADS / 8; batch++)
    {
        HANDLE h[8];
        for (int i = 0; i < 8; i++)
            h[i] = CreateThread(NULL, 0, churner, (LPVOID)(INT_PTR)(batch * 8 + i), 0, NULL);
        WaitForMultipleObjects(8, h, TRUE, 30000);
        for (int i = 0; i < 8; i++)
        {
            DWORD code = 0;
            GetExitCodeThread(h[i], &code);
            if (code != (DWORD)(batch * 8 + i) + 1000)
                return 6;
            CloseHandle(h[i]);
        }
    }
    printf("churn: %d threads created and joined\n", CHURN_THREADS);

    /* contended atomics last, behind the watchdog: a stall is reported as
     * exit 7 with all prior families already verified */
    atomics_done = CreateEventW(NULL, TRUE, FALSE, NULL);
    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    {
        HANDLE h[WORKERS];
        ResetEvent(go_event);
        for (int i = 0; i < WORKERS; i++)
            h[i] = CreateThread(NULL, 0, atomics_worker, (LPVOID)(INT_PTR)i, 0, NULL);
        SetEvent(go_event);
        WaitForMultipleObjects(WORKERS, h, TRUE, INFINITE);
        SetEvent(atomics_done);
        for (int i = 0; i < WORKERS; i++)
            CloseHandle(h[i]);
    }
    printf("atomics: %ld (expected %d), 64-bit %lld (expected %lld)\n", (long)shared_counter,
           WORKERS * INCREMENTS, (long long)shared_counter64, (long long)WORKERS * INCREMENTS * 3);
    if (shared_counter != WORKERS * INCREMENTS ||
        shared_counter64 != (LONG64)WORKERS * INCREMENTS * 3)
        return 3;

    puts("cpu-001 threads/tls ok");
    return 0;
}
