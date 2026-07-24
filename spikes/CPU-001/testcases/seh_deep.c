/*
 * CPU-001 deep SEH guest.
 * Author: Timur Isaev
 *
 * Exercises structured exception handling beyond the smoke test: nested
 * __try/__except to depth 32, __try/__finally unwind ordering recorded and
 * verified, RaiseException argument delivery, and a filter that inspects
 * and advances the faulting context (skip-the-instruction pattern).
 * Self-verifying; distinct exit code per failing family.
 */

#define WIN32_LEAN_AND_MEAN

#include <stdio.h>
#include <windows.h>

#define DEPTH 32

static int unwind_order[DEPTH];
static int unwind_count;

static void nest(int level)
{
    __try
    {
        if (level + 1 < DEPTH)
            nest(level + 1);
        else
            RaiseException(0xE0000042, 0, 0, NULL);
    }
    __finally
    {
        unwind_order[unwind_count++] = level;
    }
}

static DWORD filter_capture(EXCEPTION_POINTERS *pointers, DWORD *code_out, ULONG_PTR args_out[2])
{
    EXCEPTION_RECORD *record = pointers->ExceptionRecord;

    *code_out = record->ExceptionCode;
    if (record->NumberParameters >= 2)
    {
        args_out[0] = record->ExceptionInformation[0];
        args_out[1] = record->ExceptionInformation[1];
    }
    return EXCEPTION_EXECUTE_HANDLER;
}

static DWORD WINAPI seh_watchdog(LPVOID arg)
{
    (void)arg;
    Sleep(15000);
    /* known FEX finding: continue-execution with a modified Rip never
     * resumes; report instead of hanging */
    puts("rip skip: RESUME HANG (>15s) - known FEX continue-execution finding");
    ExitProcess(6);
}

static DWORD filter_skip(EXCEPTION_POINTERS *pointers)
{
    /* ud2 is two bytes: advance rip past it and resume */
    if (pointers->ExceptionRecord->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION)
        return EXCEPTION_CONTINUE_SEARCH;
    pointers->ContextRecord->Rip += 2;
    return EXCEPTION_CONTINUE_EXECUTION;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    /* nested finally unwind order: innermost first */
    {
        int caught = 0;

        __try
        {
            nest(0);
        }
        __except (GetExceptionCode() == 0xE0000042 ? EXCEPTION_EXECUTE_HANDLER
                                                   : EXCEPTION_CONTINUE_SEARCH)
        {
            caught = 1;
        }
        printf("nested unwind: %d finally blocks, caught=%d\n", unwind_count, caught);
        if (!caught || unwind_count != DEPTH)
            return 1;
        for (int i = 0; i < DEPTH; i++)
            if (unwind_order[i] != DEPTH - 1 - i)
            {
                printf("unwind order broken at %d: %d\n", i, unwind_order[i]);
                return 2;
            }
    }

    /* RaiseException argument delivery through the filter */
    {
        DWORD code = 0;
        ULONG_PTR args[2] = {0, 0};
        ULONG_PTR sent[2] = {0xABCDEF01, 0x12345678};

        __try
        {
            RaiseException(0xE0001234, 0, 2, sent);
        }
        __except (filter_capture(GetExceptionInformation(), &code, args))
        {
        }
        printf("raise args: code %08lX args %p %p\n", (unsigned long)code, (void *)args[0],
               (void *)args[1]);
        if (code != 0xE0001234 || args[0] != sent[0] || args[1] != sent[1])
            return 3;
    }

    /* AV address reporting precision */
    {
        volatile char *target = (volatile char *)(ULONG_PTR)0x7f00beef000ull;
        ULONG_PTR reported = 0;
        DWORD code = 0;
        ULONG_PTR args[2] = {0, 0};

        __try
        {
            *target = 1;
        }
        __except (filter_capture(GetExceptionInformation(), &code, args))
        {
            reported = args[1];
        }
        printf("av address: code %08lX addr %p (expected %p write)\n", (unsigned long)code,
               (void *)reported, (void *)target);
        if (code != EXCEPTION_ACCESS_VIOLATION || reported != (ULONG_PTR)target || args[0] != 1)
            return 5;
    }

    CreateThread(NULL, 0, seh_watchdog, NULL, 0, NULL);
    /* continue-execution after advancing rip past ud2 */
    {
        volatile int after = 0;

        __try
        {
            __asm__ volatile("ud2");
            after = 42;
        }
        __except (filter_skip(GetExceptionInformation()))
        {
            after = -1;
        }
        printf("rip skip: after=%d\n", after);
        if (after != 42)
            return 4;
    }

    puts("cpu-001 seh deep ok");
    return 0;
}
