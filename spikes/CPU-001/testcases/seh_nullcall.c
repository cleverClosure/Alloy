/*
 * CPU-001 null-function-pointer dispatch test.
 * Author: Tim Isaev
 *
 * Guards the one case where a guest exception legitimately carries RIP 0: the
 * guest branches into the null page, which arrives as an instruction-fetch
 * access violation at address 0. FEX's null-RIP dispatch refusal (issue #6)
 * must let this through and dispatch it to the guest handler; refusing it
 * would break the very common "call through an uninitialised vtable/import"
 * crash path that titles catch themselves.
 *
 * Both the main thread and worker threads run it, repeatedly, because the
 * refusal is evaluated per dispatch and the multi-worker path is the one
 * issue #6 is about.
 *
 * Exit 0 = every null call was caught with the expected code and address.
 * Exit 22 = a catch was lost; exit 23 = wrong exception detail; exit 9 = stall.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <windows.h>

#define WORKERS 3
#define ITERS 25

typedef void (*nullfn_t)(void);

static volatile LONG caught;
static volatile LONG detail_bad;

/* Kept noinline so the __try scope survives -O2 (result 10, cause 1). */
__attribute__((noinline)) static int call_through_null(void)
{
    __try
    {
        nullfn_t fn = (nullfn_t)0;
        fn();
        return 0;
    }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER
                                                               : EXCEPTION_CONTINUE_SEARCH)
    {
        return 1;
    }
}

/* Separate scope so the filter can inspect the record without the handler body
 * perturbing the first test's codegen. */
static int last_info0 = -1;
static ULONG_PTR last_addr = ~(ULONG_PTR)0;

static int null_filter(EXCEPTION_POINTERS *ep)
{
    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;
    if (ep->ExceptionRecord->NumberParameters >= 2)
    {
        last_info0 = (int)ep->ExceptionRecord->ExceptionInformation[0];
        last_addr = ep->ExceptionRecord->ExceptionInformation[1];
    }
    return EXCEPTION_EXECUTE_HANDLER;
}

__attribute__((noinline)) static int call_through_null_inspect(void)
{
    __try
    {
        nullfn_t fn = (nullfn_t)0;
        fn();
        return 0;
    }
    __except (null_filter(GetExceptionInformation()))
    {
        return 1;
    }
}

static DWORD WINAPI worker(LPVOID arg)
{
    int i;

    (void)arg;
    for (i = 0; i < ITERS; i++)
        if (call_through_null())
            InterlockedIncrement(&caught);
    return 0;
}

static DWORD WINAPI watchdog(LPVOID arg)
{
    (void)arg;
    Sleep(60000);
    printf("null call: STALL (>60s), %ld caught\n", (long)caught);
    ExitProcess(9);
}

int main(void)
{
    HANDLE workers[WORKERS];
    int expected = (WORKERS + 1) * ITERS;
    int i;

    setvbuf(stdout, NULL, _IONBF, 0);
    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);

    /* One inspected call first, to confirm the exception really is an
     * instruction-fetch fault at address 0 and not something else. */
    if (!call_through_null_inspect())
    {
        printf("null call: inspected call was NOT caught\n");
        return 22;
    }
    printf("null call detail: info0=%d addr=0x%llx (expect info0=8 addr=0x0)\n", last_info0,
           (unsigned long long)last_addr);
    if (last_info0 != 8 || last_addr != 0)
        detail_bad = 1;
    InterlockedIncrement(&caught);

    for (i = 0; i < ITERS - 1; i++)
        if (call_through_null())
            InterlockedIncrement(&caught);

    for (i = 0; i < WORKERS; i++)
        workers[i] = CreateThread(NULL, 0, worker, (LPVOID)(INT_PTR)i, 0, NULL);
    WaitForMultipleObjects(WORKERS, workers, TRUE, INFINITE);
    for (i = 0; i < WORKERS; i++)
        CloseHandle(workers[i]);

    printf("null call: %ld/%d caught\n", (long)caught, expected);
    if (caught != expected)
        return 22;
    if (detail_bad)
    {
        printf("null call: unexpected exception detail\n");
        return 23;
    }
    puts("cpu-001 seh nullcall ok");
    return 0;
}
