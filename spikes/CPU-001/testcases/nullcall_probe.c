/*
 * Diagnostic probe for issue #20: report what a guest exception filter sees
 * when the guest branches through a null function pointer.
 * Author: Tim Isaev
 *
 * seh_nullcall's filter declines the exception even though the record carries
 * the right code and ExceptionInformation. That could be the code, the
 * information, the reported address, or the filter never running at all, and
 * those have different fixes. Print every field from inside the filter and
 * from a vectored handler, so the reason is read rather than guessed.
 *
 * MUST be built with -Xclang -fasync-exceptions; see build-corpus.sh.
 */

#include <windows.h>

#include <stdio.h>

typedef void (*nullfn_t)(void);

static LONG CALLBACK veh(EXCEPTION_POINTERS *ep)
{
    EXCEPTION_RECORD *r = ep->ExceptionRecord;

    printf("VEH    code=%08lx addr=%p params=%lu info0=%llu info1=%llx rip=%llx rsp=%llx\n",
           (unsigned long)r->ExceptionCode, r->ExceptionAddress, (unsigned long)r->NumberParameters,
           r->NumberParameters >= 1 ? (unsigned long long)r->ExceptionInformation[0] : 0ULL,
           r->NumberParameters >= 2 ? (unsigned long long)r->ExceptionInformation[1] : 0ULL,
           (unsigned long long)ep->ContextRecord->Rip, (unsigned long long)ep->ContextRecord->Rsp);
    fflush(stdout);
    return EXCEPTION_CONTINUE_SEARCH;
}

static int filter(EXCEPTION_POINTERS *ep)
{
    EXCEPTION_RECORD *r = ep->ExceptionRecord;

    printf("FILTER code=%08lx addr=%p params=%lu info0=%llu info1=%llx rip=%llx rsp=%llx\n",
           (unsigned long)r->ExceptionCode, r->ExceptionAddress, (unsigned long)r->NumberParameters,
           r->NumberParameters >= 1 ? (unsigned long long)r->ExceptionInformation[0] : 0ULL,
           r->NumberParameters >= 2 ? (unsigned long long)r->ExceptionInformation[1] : 0ULL,
           (unsigned long long)ep->ContextRecord->Rip, (unsigned long long)ep->ContextRecord->Rsp);
    fflush(stdout);
    return EXCEPTION_EXECUTE_HANDLER;
}

/* Control: a data access violation through a null pointer. This already
 * dispatches correctly today, so anything that differs between the two is a
 * property of the execute-fault path rather than of null faults generally. */
__attribute__((noinline)) static int read_through_null(void)
{
    volatile int *p = (volatile int *)0;
    int v;

    __try
    {
        v = *p;
        (void)v;
        return 0;
    }
    __except (filter(GetExceptionInformation()))
    {
        return 1;
    }
}

__attribute__((noinline)) static int call_through_null(void)
{
    __try
    {
        nullfn_t fn = (nullfn_t)0;
        fn();
        return 0;
    }
    __except (filter(GetExceptionInformation()))
    {
        return 1;
    }
}

int main(void)
{
    int caught_read, caught_call;

    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    AddVectoredExceptionHandler(1, veh);

    printf("-- control: read through null --\n");
    fflush(stdout);
    caught_read = read_through_null();
    printf("read caught=%d\n", caught_read);

    printf("-- subject: call through null --\n");
    fflush(stdout);
    caught_call = call_through_null();
    printf("call caught=%d\n", caught_call);

    fflush(stdout);
    return (caught_read && caught_call) ? 0 : 1;
}
