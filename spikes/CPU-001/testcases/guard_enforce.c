/*
 * CPU-001 guard-page enforcement experiment.
 * Author: Timur Isaev
 *
 * The FEX guard-granularity fix rests on one physical claim: a 4 KB
 * PAGE_NOACCESS protection is NOT enforced on a 16 KB-page host (its host
 * page is shared with accessible neighbours, so the permissive vprot union
 * keeps the whole host page writable), while a full host-page (16 KB)
 * protection IS enforced. This proves or refutes that claim directly, over
 * the same Wine NtProtectVirtualMemory path FEX's guards use.
 *
 * Fault detection is by PROCESS EXIT, never in-process SEH: FEX's exception
 * dispatch wedges on a caught hardware fault (CPU-001 result 08), so a
 * __try/__except around the guarded write would hang rather than report.
 * Each case runs as its own child that writes the guarded page and, if it
 * survives, exits 0. A crash (unhandled AV, winedbg disabled in the prefix)
 * means the guard was enforced.
 *
 *   child A: last 4 KB of a committed 16 KB host page -> NOACCESS -> write.
 *            exit 0 = unenforced (shear); crash = enforced.
 *   child B: full 16 KB host page -> NOACCESS -> write.
 *            exit 0 = not enforced; crash = enforced.
 *
 * The fix is validated iff A survives (4 KB guard unenforceable) and B
 * crashes (16 KB guard enforceable).
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <string.h>
#include <windows.h>

#define K4 0x1000u
#define K16 0x4000u

static int child_write(int full_host_page)
{
    unsigned char *region = VirtualAlloc(NULL, 2 * K16, MEM_RESERVE, PAGE_NOACCESS);
    DWORD old;

    if (!region || !VirtualAlloc(region, K16, MEM_COMMIT, PAGE_READWRITE))
        return 2;
    memset(region, 0, K16);

    if (full_host_page)
    {
        if (!VirtualProtect(region, K16, PAGE_NOACCESS, &old))
            return 3;
        region[0] = 0x5A; /* faults iff the 16 KB guard is enforced */
    }
    else
    {
        if (!VirtualProtect(region + K16 - K4, K4, PAGE_NOACCESS, &old))
            return 3;
        region[K16 - K4] = 0x5A; /* faults iff the 4 KB guard is enforced */
    }
    return 0; /* reached only if the write did not fault */
}

static int run_child(const char *self, const char *arg, DWORD *exit_code)
{
    WCHAR command[MAX_PATH * 2];
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;

    _snwprintf(command, MAX_PATH * 2, L"\"%hs\" %hs", self, arg);
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
        return 0;
    if (WaitForSingleObject(process.hProcess, 30000) != WAIT_OBJECT_0)
    {
        TerminateProcess(process.hProcess, 0xFFFFFFFF);
        return 0;
    }
    GetExitCodeProcess(process.hProcess, exit_code);
    CloseHandle(process.hProcess);
    CloseHandle(process.hThread);
    return 1;
}

int main(int argc, char **argv)
{
    DWORD a_code = 0, b_code = 0;
    int a_crash, b_crash;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc == 2 && strcmp(argv[1], "childA") == 0)
        return child_write(0);
    if (argc == 2 && strcmp(argv[1], "childB") == 0)
        return child_write(1);

    if (!run_child(argv[0], "childA", &a_code) || !run_child(argv[0], "childB", &b_code))
    {
        puts("child spawn/timeout failure");
        return 1;
    }
    a_crash = (a_code >= 0xC0000000u);
    b_crash = (b_code >= 0xC0000000u);
    printf("case A (4KB guard on shared host page): child exit 0x%08lX -> %s\n",
           (unsigned long)a_code, a_crash ? "FAULTED (enforced)" : "survived (UNENFORCED - shear)");
    printf("case B (full 16KB host-page guard):     child exit 0x%08lX -> %s\n",
           (unsigned long)b_code, b_crash ? "FAULTED (enforced)" : "survived (NOT enforced)");

    if (a_crash)
    {
        puts("result: 4KB guard already enforced - fix unnecessary on this host");
        return 10;
    }
    if (!b_crash)
    {
        puts("result: 16KB guard NOT enforced - fix does not help; deeper problem");
        return 11;
    }
    puts("result: 4KB guard unenforceable, 16KB guard enforceable - FEX fix validated");
    return 0;
}
