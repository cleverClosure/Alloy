/* Known-answer access-violation census control. Author: Timur Isaev */
#include <windows.h>

#include <stdio.h>

#ifndef PROVOKE_FAULT
#define PROVOKE_FAULT 0
#endif

#define ITERATIONS 64

__attribute__((noinline)) static int read_one(volatile unsigned char *address)
{
    __try
    {
        return *address == 0 ? 0 : -1;
    }
    __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION ? EXCEPTION_EXECUTE_HANDLER
                                                               : EXCEPTION_CONTINUE_SEARCH)
    {
        return 1;
    }
}

int main(void)
{
    unsigned char *page;
    DWORD old;
    int caught = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    page = VirtualAlloc(NULL, 16384, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!page || !VirtualProtect(page, 16384, PROVOKE_FAULT ? PAGE_NOACCESS : PAGE_READONLY, &old))
        return 2;
    printf("anomaly_fault begin provoke=%d iterations=%d\n", PROVOKE_FAULT, ITERATIONS);
    for (int i = 0; i < ITERATIONS; ++i)
    {
        int result = read_one(page);
        if (result < 0)
            return 3;
        caught += result;
    }
    printf("anomaly_fault end caught=%d expected=%d\n", caught, PROVOKE_FAULT * ITERATIONS);
    VirtualFree(page, 0, MEM_RELEASE);
    return caught == PROVOKE_FAULT * ITERATIONS ? 0 : 1;
}
