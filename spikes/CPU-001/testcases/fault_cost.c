/*
 * CPU-001 fault round-trip and protection-change cost benchmark.
 * Author: Timur Isaev
 *
 * Produces the per-operation costs the shear-enforcement decision needs:
 * a handled access violation is the upper bound for one spurious fault under
 * a restrictive-union design, and VirtualProtect is the unit cost of any
 * protection flip-flop scheme.
 */

#include <stdint.h>
#include <stdio.h>
#include <windows.h>

enum
{
    BASELINE_READS = 8 * 1024 * 1024,
    FAULT_ROUNDS = 1000,
    PROTECT_ROUNDS = 5000,
    QUERY_ROUNDS = 10000
};

static volatile LONG expected_faults;
static void *expected_address;

static LONG CALLBACK fault_handler(EXCEPTION_POINTERS *pointers)
{
    EXCEPTION_RECORD *record = pointers->ExceptionRecord;

    if (record->ExceptionCode != EXCEPTION_ACCESS_VIOLATION || record->NumberParameters < 2 ||
        record->ExceptionInformation[0] != 0 ||
        record->ExceptionInformation[1] != (ULONG_PTR)expected_address)
        return EXCEPTION_CONTINUE_SEARCH;
    if (!expected_faults)
        return EXCEPTION_CONTINUE_SEARCH;

    InterlockedDecrement(&expected_faults);
    pointers->ContextRecord->Rip += 2; /* movl (%rax), %eax */
    return EXCEPTION_CONTINUE_EXECUTION;
}

static uint64_t elapsed_ns(LARGE_INTEGER start, LARGE_INTEGER end, LARGE_INTEGER frequency)
{
    return (uint64_t)(end.QuadPart - start.QuadPart) * 1000000000ull / (uint64_t)frequency.QuadPart;
}

static void read_expected_address(void)
{
    __asm__ volatile("mov %0, %%rax\n\t"
                     ".byte 0x8b, 0x00"
                     :
                     : "r"(expected_address)
                     : "rax", "memory");
}

int main(void)
{
    LARGE_INTEGER frequency, start, end;
    unsigned char *buffer;
    unsigned char *fault_page;
    volatile unsigned char *reader;
    DWORD old_protection;
    MEMORY_BASIC_INFORMATION query;
    PVOID handler;
    uint64_t baseline_ns, fault_ns, protect_ns, query_ns;
    unsigned int sum = 0;
    unsigned int i;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (!QueryPerformanceFrequency(&frequency))
        return 1;
    handler = AddVectoredExceptionHandler(1, fault_handler);
    if (!handler)
        return 2;
    buffer = VirtualAlloc(NULL, 0x10000, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!buffer)
        return 3;

    reader = buffer;
    QueryPerformanceCounter(&start);
    for (i = 0; i < BASELINE_READS; i++)
        sum += reader[i & 0xefff];
    QueryPerformanceCounter(&end);
    baseline_ns = elapsed_ns(start, end, frequency);
    printf("plain read: %u.%03u ns/op (%u ops, checksum %u)\n",
           (unsigned int)(baseline_ns / BASELINE_READS),
           (unsigned int)(baseline_ns * 1000 / BASELINE_READS % 1000), BASELINE_READS, sum);

    /* The protected page must be alone in its 16 KB host page (siblings left
     * uncommitted) so enforcement survives the shear defect and the fault is
     * actually deliverable. */
    fault_page = VirtualAlloc(NULL, 0x10000, MEM_RESERVE, PAGE_NOACCESS);
    if (!fault_page)
        return 4;
    if (!VirtualAlloc(fault_page, 0x1000, MEM_COMMIT, PAGE_NOACCESS))
        return 5;
    expected_address = fault_page;
    expected_faults = 1;
    read_expected_address();
    if (expected_faults)
    {
        puts("fault benchmark skipped: isolated protected read did not fault");
        expected_faults = 0;
    }
    else
    {
        expected_faults = FAULT_ROUNDS;
        QueryPerformanceCounter(&start);
        for (i = 0; i < FAULT_ROUNDS; i++)
            read_expected_address();
        QueryPerformanceCounter(&end);
        if (expected_faults)
            return 6;
        fault_ns = elapsed_ns(start, end, frequency);
        printf("handled access violation: %u ns/op (%u ops)\n",
               (unsigned int)(fault_ns / FAULT_ROUNDS), FAULT_ROUNDS);
    }
    expected_address = NULL;
    if (!VirtualFree(fault_page, 0, MEM_RELEASE))
        return 7;

    QueryPerformanceCounter(&start);
    for (i = 0; i < PROTECT_ROUNDS; i++)
    {
        if (!VirtualProtect(buffer + 0x1000, 0x1000, PAGE_READONLY, &old_protection))
            return 8;
        if (!VirtualProtect(buffer + 0x1000, 0x1000, PAGE_READWRITE, &old_protection))
            return 9;
    }
    QueryPerformanceCounter(&end);
    protect_ns = elapsed_ns(start, end, frequency);
    printf("VirtualProtect: %u ns/op (%u ops)\n", (unsigned int)(protect_ns / (2 * PROTECT_ROUNDS)),
           2 * PROTECT_ROUNDS);

    QueryPerformanceCounter(&start);
    for (i = 0; i < QUERY_ROUNDS; i++)
        if (!VirtualQuery(buffer, &query, sizeof(query)))
            return 10;
    QueryPerformanceCounter(&end);
    query_ns = elapsed_ns(start, end, frequency);
    printf("VirtualQuery: %u ns/op (%u ops)\n", (unsigned int)(query_ns / QUERY_ROUNDS),
           QUERY_ROUNDS);

    if (!VirtualFree(buffer, 0, MEM_RELEASE))
        return 11;
    if (!RemoveVectoredExceptionHandler(handler))
        return 12;
    puts("cpu-001 fault-cost benchmark done");
    return 0;
}
