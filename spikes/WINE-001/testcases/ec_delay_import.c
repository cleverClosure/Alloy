/*
 * ARM64EC variadic delay-import ABI probe.
 *
 * Author: Tim Isaev
 *
 * OpenSCManagerW is implemented by sechost.dll, whose ARM64EC code reaches the
 * variadic rpcrt4!NdrClientCall2 through the auxiliary delay-load IAT.  Until
 * that slot is snapped, the first call detours through the x64 exit thunk and
 * every argument past the fourth is lost, so ROpenSCManagerW receives a bogus
 * [out] context-handle pointer and rpcrt4 writes NULL through it.  This guest
 * fails at the same rpcrt4 address that ends Deus Ex: Mankind Divided's
 * startup; see
 * spikes/GFX-001/results/2026-07-25-07-deus-ex-title-scene-blocked.md.
 *
 * Expected today: "FAIL raised 0xc0000005 at ..." from the vectored handler,
 * exit 3.  A fixed runtime prints PASS and exits 0.
 *
 * Keep the built image name short.  One byte-identical binary reproduces this
 * fault as ec_delay_import.exe (15-character stem) but raises
 * STATUS_ILLEGAL_INSTRUCTION before main, exit 29, as
 * arm64ec_delay_import.exe (20).  Adding WIN32_LEAN_AND_MEAN or building with
 * -Xclang -fasync-exceptions does the same.  That masking failure is a
 * separate emulator defect, not the one under test.  The stage lines tell them
 * apart: a run that prints nothing never reached main and proves nothing about
 * delay imports.
 */

#include <windows.h>
#include <winsvc.h>
#include <stdio.h>

static LONG CALLBACK on_fault(EXCEPTION_POINTERS *info)
{
    printf("FAIL raised %#lx at %p\n", info->ExceptionRecord->ExceptionCode,
           info->ExceptionRecord->ExceptionAddress);
    fflush(stdout);
    ExitProcess(3);
    return EXCEPTION_CONTINUE_SEARCH;
}

int main(void)
{
    SC_HANDLE m;

    printf("start\n");
    fflush(stdout);
    AddVectoredExceptionHandler(1, on_fault);
    printf("veh installed\n");
    fflush(stdout);
    m = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    printf("manager=%p\n", (void *)m);
    fflush(stdout);
    if (m)
    {
        CloseServiceHandle(m);
        puts("PASS");
        return 0;
    }
    return 4;
}
