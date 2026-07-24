/*
 * CPU-001 x64 JIT, W^X, page-shear, and self-modifying-code smoke test.
 * Author: Timur Isaev
 */

#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>

enum expected_fault
{
    FAULT_NONE,
    FAULT_NOACCESS_READ,
    FAULT_RX_WRITE
};

static volatile LONG expected_fault;
static volatile LONG handled_faults;
static void *expected_address;

static LONG CALLBACK fault_handler(EXCEPTION_POINTERS *pointers)
{
    EXCEPTION_RECORD *record = pointers->ExceptionRecord;
    CONTEXT *context = pointers->ContextRecord;

    if (record->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || record->NumberParameters < 2 ||
        record->ExceptionInformation[1] != (ULONG_PTR)expected_address)
        return EXCEPTION_CONTINUE_SEARCH;

    if (expected_fault == FAULT_NOACCESS_READ)
    {
        if (record->ExceptionInformation[0] != 0)
            return EXCEPTION_CONTINUE_SEARCH;
        context->Rip += 2; /* movl (%rax), %eax */
    }
    else if (expected_fault == FAULT_RX_WRITE)
    {
        if (record->ExceptionInformation[0] != 1)
            return EXCEPTION_CONTINUE_SEARCH;
        context->Rip += 3; /* movb $0x90, (%rax) */
    }
    else
    {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    expected_fault = FAULT_NONE;
    InterlockedIncrement(&handled_faults);
    return EXCEPTION_CONTINUE_EXECUTION;
}

static void emit_return_constant(unsigned char *code, uint32_t value)
{
    code[0] = 0xb8; /* mov eax, imm32 */
    memcpy(code + 1, &value, sizeof(value));
    code[5] = 0xc3; /* ret */
}

static int call_code(unsigned char *code)
{
    int (*function)(void) = (int (*)(void))code;

    return function();
}

static int protect_code(unsigned char *address, SIZE_T size, DWORD protection)
{
    DWORD old_protection;

    return VirtualProtect(address, size, protection, &old_protection) &&
           FlushInstructionCache(GetCurrentProcess(), address, size);
}

static int test_jit_transition_at(unsigned char *allocation, SIZE_T allocation_size, SIZE_T offset,
                                  uint32_t first, uint32_t second)
{
    unsigned char *code = allocation + offset;

    if (!protect_code(allocation, allocation_size, PAGE_READWRITE))
        return 0;
    emit_return_constant(code, first);
    if (!protect_code(allocation, allocation_size, PAGE_EXECUTE_READ))
        return 0;
    if ((uint32_t)call_code(code) != first)
        return 0;

    if (!protect_code(allocation, allocation_size, PAGE_READWRITE))
        return 0;
    emit_return_constant(code, second);
    if (!protect_code(allocation, allocation_size, PAGE_EXECUTE_READ))
        return 0;
    return (uint32_t)call_code(code) == second;
}

static int test_rx_write_fault(unsigned char *allocation, SIZE_T allocation_size)
{
    unsigned char original = allocation[0];

    if (!protect_code(allocation, allocation_size, PAGE_EXECUTE_READ))
        return 0;
    expected_address = allocation;
    expected_fault = FAULT_RX_WRITE;
    __asm__ volatile("mov %0, %%rax\n\t"
                     ".byte 0xc6, 0x00, 0x90"
                     :
                     : "r"(allocation)
                     : "rax", "memory");
    expected_address = NULL;
    return expected_fault == FAULT_NONE && allocation[0] == original;
}

static int test_4k_subpage_protection(unsigned char *allocation, SIZE_T allocation_size)
{
    MEMORY_BASIC_INFORMATION query;
    SIZE_T query_size;
    DWORD old_protection;
    LONG faults_before;
    volatile unsigned char before;
    volatile unsigned char after;

    if (!protect_code(allocation, allocation_size, PAGE_READWRITE))
        return 0;
    allocation[0x0fff] = 0x3c;
    allocation[0x1000] = 0x4d;
    allocation[0x2000] = 0x5e;

    if (!VirtualProtect(allocation + 0x1000, 0x1000, PAGE_NOACCESS, &old_protection))
    {
        printf("4 KB subpage: PAGE_NOACCESS failed, error=%lu\n", GetLastError());
        return 0;
    }

    before = allocation[0x0fff];
    after = allocation[0x2000];
    faults_before = handled_faults;
    expected_address = allocation + 0x1000;
    expected_fault = FAULT_NOACCESS_READ;
    __asm__ volatile("mov %0, %%rax\n\t"
                     ".byte 0x8b, 0x00"
                     :
                     : "r"(allocation + 0x1000)
                     : "rax", "memory");
    expected_address = NULL;
    query_size = VirtualQuery(allocation + 0x1000, &query, sizeof(query));

    if (!VirtualProtect(allocation + 0x1000, 0x1000, PAGE_READWRITE, &old_protection))
    {
        printf("4 KB subpage: PAGE_READWRITE restore failed, error=%lu\n", GetLastError());
        return 0;
    }
    if (expected_fault != FAULT_NONE)
    {
        printf("4 KB subpage: protected guest read did not fault; handled delta=%ld\n",
               handled_faults - faults_before);
        if (query_size)
            printf("4 KB subpage: pre-restore VirtualQuery base=%p size=%08zx "
                   "state=%08lx protect=%08lx\n",
                   query.BaseAddress, (size_t)query.RegionSize, query.State, query.Protect);
        expected_fault = FAULT_NONE;
        return 0;
    }
    if (before != 0x3c || after != 0x5e)
    {
        printf("4 KB subpage: adjacent bytes changed, before=%02x after=%02x\n", before, after);
        return 0;
    }
    return 1;
}

static int test_cross_page_avx2(unsigned char *allocation, SIZE_T allocation_size)
{
    unsigned char expected[32];
    unsigned char observed[32];
    __m256i value;
    unsigned int i;

    if (!protect_code(allocation, allocation_size, PAGE_READWRITE))
        return 0;
    for (i = 0; i < sizeof(expected); i++)
    {
        expected[i] = (unsigned char)(i * 7 + 3);
        allocation[0x0ff0 + i] = expected[i];
    }

    value = _mm256_loadu_si256((const __m256i *)(allocation + 0x0ff0));
    _mm256_storeu_si256((__m256i *)observed, value);
    return !memcmp(expected, observed, sizeof(expected));
}

int main(void)
{
    const SIZE_T allocation_size = 0x10000;
    unsigned char *allocation;
    PVOID handler;

    setvbuf(stdout, NULL, _IONBF, 0);
    handler = AddVectoredExceptionHandler(1, fault_handler);
    if (!handler)
        return 1;

    allocation = VirtualAlloc(NULL, allocation_size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!allocation)
        return 2;

    if (!test_jit_transition_at(allocation, allocation_size, 0x0100, 0x11223344, 0x55667788))
        return 3;
    puts("JIT W^X transition and code invalidation: ok");

    if (!test_jit_transition_at(allocation, allocation_size, 0x0ffe, 0x13579bdf, 0x2468ace0))
        return 4;
    puts("guest 4 KB instruction-boundary crossing: ok");

    if (!test_jit_transition_at(allocation, allocation_size, 0x3ffe, 0x10203040, 0x50607080))
        return 5;
    puts("host 16 KB instruction-boundary crossing: ok");

    if (!test_rx_write_fault(allocation, allocation_size))
        return 6;
    puts("RX write rejection: ok");

    if (!test_4k_subpage_protection(allocation, allocation_size))
        return 7;
    puts("4 KB protection inside 16 KB host page: ok");

    if (!test_cross_page_avx2(allocation, allocation_size))
        return 8;
    puts("cross-page unaligned AVX2 load: ok");

    if (!VirtualFree(allocation, 0, MEM_RELEASE))
        return 9;
    if (!RemoveVectoredExceptionHandler(handler))
        return 10;
    if (handled_faults != 2)
        return 11;

    printf("cpu-001 JIT/page semantics ok: faults=%ld\n", handled_faults);
    return 0;
}
