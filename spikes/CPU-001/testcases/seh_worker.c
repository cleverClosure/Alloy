/*
 * CPU-001 single-worker caught-AV probe.
 * Author: Tim Isaev
 *
 * Minimal discriminator for the worker-thread SEH gap: one CreateThread
 * worker takes one null-write AV under __try/__except and must catch it.
 * The identical pattern on the main thread is the control. Exit codes:
 *   0 = both caught, 1 = main-thread catch failed, 2 = worker catch failed,
 *   3 = worker never finished (10s), 4 = spawn failure.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <windows.h>

static volatile LONG worker_caught;

__attribute__((noinline)) static int catch_null_write(void)
{
    __try
    {
        volatile int *null_ptr = NULL;
        *null_ptr = 7;
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
    (void)arg;
    if (catch_null_write())
        InterlockedIncrement(&worker_caught);
    return 0;
}

int main(void)
{
    HANDLE worker;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (!catch_null_write())
    {
        puts("main thread: NOT caught");
        return 1;
    }
    puts("main thread: caught");

    worker = CreateThread(NULL, 0, av_worker, NULL, 0, NULL);
    if (!worker)
        return 4;
    if (WaitForSingleObject(worker, 10000) != WAIT_OBJECT_0)
    {
        puts("worker: TIMEOUT");
        TerminateThread(worker, 0);
        return 3;
    }
    if (!worker_caught)
    {
        puts("worker: NOT caught");
        return 2;
    }
    puts("worker: caught");
    puts("cpu-001 seh worker ok");
    return 0;
}
