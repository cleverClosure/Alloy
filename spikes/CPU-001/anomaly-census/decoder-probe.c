/* Separate binaries prevent the decoder walking unused positive sites.
 * Author: Timur Isaev */
#include <windows.h>

#include <stdio.h>

#ifndef PROBE_KIND
#define PROBE_KIND 0
#endif

__attribute__((noinline)) static int invoke(void (*code)(void))
{
    __try
    {
        code();
        return 0;
    }
    __except (GetExceptionCode() == EXCEPTION_ILLEGAL_INSTRUCTION ? EXCEPTION_EXECUTE_HANDLER
                                                                  : EXCEPTION_CONTINUE_SEARCH)
    {
        return 1;
    }
}

int main(void)
{
    unsigned char *code;
    DWORD old;
    int caught;

    setvbuf(stdout, NULL, _IONBF, 0);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    code = VirtualAlloc(NULL, 16384, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!code)
        return 2;
#if PROBE_KIND == 1
    code[0] = 0x06; /* PUSH ES: invalid in 64-bit mode, INVALID_INST in this FEX. */
    code[1] = 0xc3;
#elif PROBE_KIND == 2
    code[0] = 0xf0; /* LOCK NOP: illegal LOCK use, UNIMPLEMENTED_INST in this FEX. */
    code[1] = 0x90;
    code[2] = 0xc3;
#else
    code[0] = 0x90; /* NOP; RET is the matching valid negative control. */
    code[1] = 0xc3;
#endif
    if (!VirtualProtect(code, 16384, PAGE_EXECUTE_READ, &old) ||
        !FlushInstructionCache(GetCurrentProcess(), code, 16384))
        return 3;
    printf("anomaly_decoder begin kind=%d address=%p\n", PROBE_KIND, (void *)code);
    caught = invoke((void (*)(void))code);
    printf("anomaly_decoder end kind=%d caught=%d expected=%d\n", PROBE_KIND, caught,
           PROBE_KIND != 0);
    VirtualFree(code, 0, MEM_RELEASE);
    return caught == (PROBE_KIND != 0) ? 0 : 1;
}
