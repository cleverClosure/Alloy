/*
 * CPU-001 simultaneous cross-thread AV detector.
 * Author: Timur Isaev
 *
 * Deliberate repro of the concurrent-guest-AV exception-dispatch deadlock:
 * N threads take an access violation at the same moment behind one event.
 * On a healthy runtime every thread catches its own AV and the process
 * exits 0 quickly; on the current FEX/EC stack the dispatch deadlocks
 * (threads parked in wait_suspend, two stuck mid-handler), which the
 * watchdog converts into exit 8 - a detector, not a hang.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <windows.h>

#define WORKERS 4

static HANDLE go_event;
static volatile LONG caught;

static DWORD WINAPI av_worker(LPVOID arg)
{
    WaitForSingleObject(go_event, INFINITE);
    __try
    {
        volatile int *null_ptr = NULL;
        *null_ptr = (int)(INT_PTR)arg;
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        InterlockedIncrement(&caught);
    }
    return 0;
}

static DWORD WINAPI watchdog(LPVOID arg)
{
    (void)arg;
    Sleep(20000);
    printf("concurrent AV: DISPATCH STALL (>20s), %ld/%d caught - known finding\n", (long)caught,
           WORKERS);
    ExitProcess(8);
}

int main(void)
{
    HANDLE workers[WORKERS];

    setvbuf(stdout, NULL, _IONBF, 0);
    go_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    for (int i = 0; i < WORKERS; i++)
        workers[i] = CreateThread(NULL, 0, av_worker, (LPVOID)(INT_PTR)i, 0, NULL);
    SetEvent(go_event);
    WaitForMultipleObjects(WORKERS, workers, TRUE, INFINITE);
    printf("concurrent AV: %ld/%d caught\n", (long)caught, WORKERS);
    if (caught != WORKERS)
        return 1;
    puts("cpu-001 seh concurrent ok");
    return 0;
}
