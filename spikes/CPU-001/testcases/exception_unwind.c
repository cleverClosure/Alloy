/*
 * CPU-001 x64 exception, unwind, and mixed-callback smoke test.
 * Author: Timur Isaev
 */

#define _WIN32_WINNT 0x0600

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <windows.h>

#define CPU001_EXCEPTION 0xe0421001u

enum expected_exception
{
    EXPECT_NONE,
    EXPECT_CUSTOM,
    EXPECT_ILLEGAL,
    EXPECT_ACCESS,
    EXPECT_GUARD
};

static volatile LONG expected;
static volatile LONG handled;
static volatile LONG callback_count;
static volatile LONG callback_thread_ok;
static DWORD main_thread_id;
static void *guard_address;
static jmp_buf jump_buffer;

static LONG CALLBACK exception_handler(EXCEPTION_POINTERS *pointers)
{
    EXCEPTION_RECORD *record = pointers->ExceptionRecord;
    CONTEXT *context = pointers->ContextRecord;

    switch (expected)
    {
    case EXPECT_CUSTOM:
        if (record->ExceptionCode != CPU001_EXCEPTION || record->NumberParameters != 2 ||
            record->ExceptionInformation[0] != 0x1234 || record->ExceptionInformation[1] != 0x5678)
            return EXCEPTION_CONTINUE_SEARCH;
        break;
    case EXPECT_ILLEGAL:
        if (record->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION)
            return EXCEPTION_CONTINUE_SEARCH;
        context->Rip += 2; /* ud2 */
        break;
    case EXPECT_ACCESS:
        if (record->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || record->NumberParameters < 2 ||
            record->ExceptionInformation[0] != 0 || record->ExceptionInformation[1] != 0)
            return EXCEPTION_CONTINUE_SEARCH;
        context->Rip += 2; /* movl (%rax), %eax */
        break;
    case EXPECT_GUARD:
        if (record->ExceptionCode != STATUS_GUARD_PAGE_VIOLATION || record->NumberParameters < 2 ||
            record->ExceptionInformation[1] != (ULONG_PTR)guard_address)
            return EXCEPTION_CONTINUE_SEARCH;
        break;
    default:
        return EXCEPTION_CONTINUE_SEARCH;
    }

    InterlockedIncrement(&handled);
    expected = EXPECT_NONE;
    return EXCEPTION_CONTINUE_EXECUTION;
}

__declspec(noinline) static void raise_custom_exception(void)
{
    ULONG_PTR arguments[2] = {0x1234, 0x5678};

    RaiseException(CPU001_EXCEPTION, 0, 2, arguments);
}

__declspec(noinline) static void raise_illegal_instruction(void)
{
    __asm__ volatile("ud2");
}

__declspec(noinline) static void raise_access_violation(void)
{
    __asm__ volatile("xor %%rax, %%rax\n\t"
                     ".byte 0x8b, 0x00"
                     :
                     :
                     : "rax", "memory");
}

__declspec(noinline) static unsigned int capture_frames(void **frames, unsigned int count)
{
    volatile ULONG_PTR keep_frame = (ULONG_PTR)frames;
    unsigned int captured = RtlCaptureStackBackTrace(0, count, frames, NULL);

    if (!keep_frame)
        return 0;
    return captured;
}

__declspec(noinline) static unsigned int capture_frames_level_2(void **frames, unsigned int count)
{
    unsigned int captured = capture_frames(frames, count);
    volatile unsigned int keep_frame = captured;

    return keep_frame;
}

__declspec(noinline) static unsigned int capture_frames_level_1(void **frames, unsigned int count)
{
    unsigned int captured = capture_frames_level_2(frames, count);
    volatile unsigned int keep_frame = captured;

    return keep_frame;
}

__declspec(noinline) static void jump_from_depth_2(void)
{
    longjmp(jump_buffer, 77);
}

__declspec(noinline) static void jump_from_depth_1(void)
{
    jump_from_depth_2();
}

static BOOL CALLBACK locale_callback(LPWSTR locale, DWORD flags, LPARAM parameter)
{
    (void)flags;
    (void)parameter;

    if (locale && *locale)
        InterlockedIncrement(&callback_count);
    if (GetCurrentThreadId() == main_thread_id)
        InterlockedExchange(&callback_thread_ok, 1);
    return callback_count < 4;
}

static int test_stack_capture(void)
{
    HMODULE main_module = GetModuleHandleW(NULL);
    void *frames[32] = {0};
    unsigned int captured, own_frames = 0;
    unsigned int i;

    captured = capture_frames_level_1(frames, sizeof(frames) / sizeof(frames[0]));
    for (i = 0; i < captured; i++)
    {
        HMODULE module = NULL;

        if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                   GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               (LPCWSTR)frames[i], &module) &&
            module == main_module)
            own_frames++;
    }

    printf("stack frames: captured=%u own-module=%u\n", captured, own_frames);
    return captured >= 3 && own_frames >= 2;
}

static int test_guard_page(void)
{
    SYSTEM_INFO info;
    DWORD old_protect;
    volatile unsigned char value;
    unsigned char *page;

    GetSystemInfo(&info);
    page = VirtualAlloc(NULL, info.dwPageSize, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!page)
        return 0;

    page[0] = 0x5a;
    guard_address = page;
    if (!VirtualProtect(page, info.dwPageSize, PAGE_READWRITE | PAGE_GUARD, &old_protect))
    {
        VirtualFree(page, 0, MEM_RELEASE);
        return 0;
    }

    expected = EXPECT_GUARD;
    value = page[0];
    guard_address = NULL;
    VirtualFree(page, 0, MEM_RELEASE);
    return expected == EXPECT_NONE && value == 0x5a;
}

int main(void)
{
    PVOID handler;
    int jump_value;

    puts("exception stage: entered main");
    fflush(stdout);
    setvbuf(stdout, NULL, _IONBF, 0);
    main_thread_id = GetCurrentThreadId();
    handler = AddVectoredExceptionHandler(1, exception_handler);
    if (!handler)
        return 1;
    puts("exception stage: handler installed");

    expected = EXPECT_CUSTOM;
    raise_custom_exception();
    if (expected != EXPECT_NONE)
        return 2;
    puts("exception stage: custom raise resumed");

    expected = EXPECT_ILLEGAL;
    raise_illegal_instruction();
    if (expected != EXPECT_NONE)
        return 3;
    puts("exception stage: illegal instruction resumed");

    expected = EXPECT_ACCESS;
    raise_access_violation();
    if (expected != EXPECT_NONE)
        return 4;
    puts("exception stage: access violation resumed");

    if (!test_guard_page())
        return 5;
    puts("exception stage: guard page resumed");
    if (!test_stack_capture())
        return 6;
    puts("exception stage: stack captured");

    jump_value = setjmp(jump_buffer);
    if (!jump_value)
        jump_from_depth_1();
    if (jump_value != 77)
        return 7;
    puts("exception stage: longjmp restored");

    if (!EnumSystemLocalesEx(locale_callback, LOCALE_ALL, 0, NULL))
        return 8;
    if (callback_count < 1 || !callback_thread_ok)
        return 9;
    puts("exception stage: native callback returned");

    if (!RemoveVectoredExceptionHandler(handler))
        return 10;
    if (handled != 4)
        return 11;

    printf("cpu-001 exception/unwind ok: exceptions=%ld callbacks=%ld\n", handled, callback_count);
    return 0;
}
