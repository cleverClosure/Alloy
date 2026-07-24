/*
 * CPU-001 committed-NOACCESS/guard inventory and stack-barrier enforcement probe.
 * Author: Timur Isaev
 *
 * Attributes the census noaccess-class shear events: walks the address space,
 * reports every committed PAGE_NOACCESS/PAGE_GUARD region with its allocation
 * base, marks which ones belong to a thread stack, and tests whether the
 * current stack's bottom (hard barrier) and guard actually fault when touched.
 */

#include <stdint.h>
#include <stdio.h>
#include <windows.h>

static volatile LONG probe_faulted;
static void *probe_address;

static LONG CALLBACK probe_handler(EXCEPTION_POINTERS *pointers)
{
    EXCEPTION_RECORD *record = pointers->ExceptionRecord;

    if ((record->ExceptionCode != EXCEPTION_ACCESS_VIOLATION &&
         record->ExceptionCode != STATUS_GUARD_PAGE_VIOLATION) ||
        record->NumberParameters < 2 || record->ExceptionInformation[1] != (ULONG_PTR)probe_address)
        return EXCEPTION_CONTINUE_SEARCH;

    InterlockedExchange(&probe_faulted, (LONG)record->ExceptionCode);
    pointers->ContextRecord->Rip += 2; /* movl (%rax), %eax */
    return EXCEPTION_CONTINUE_EXECUTION;
}

static LONG probe_read(void *address)
{
    probe_address = address;
    probe_faulted = 0;
    __asm__ volatile("mov %0, %%rax\n\t"
                     ".byte 0x8b, 0x00"
                     :
                     : "r"(address)
                     : "rax", "memory");
    probe_address = NULL;
    return probe_faulted;
}

static void *own_deallocation_stack(void)
{
    /* TEB64 DeallocationStack */
    return *(void **)((char *)NtCurrentTeb() + 0x1478);
}

static void describe_stack(const char *who)
{
    NT_TIB *tib = (NT_TIB *)NtCurrentTeb();
    char *base = own_deallocation_stack();
    MEMORY_BASIC_INFORMATION info;
    char *address = base;
    unsigned int i;
    LONG fault;

    printf("%s stack: deallocation=%p limit=%p base=%p\n", who, (void *)base, tib->StackLimit,
           tib->StackBase);
    for (i = 0; i < 6 && address < (char *)tib->StackBase; i++)
    {
        if (!VirtualQuery(address, &info, sizeof(info)))
            break;
        printf("%s stack region %p+%08zx state=%08lx protect=%08lx\n", who, info.BaseAddress,
               (size_t)info.RegionSize, info.State, info.Protect);
        address = (char *)info.BaseAddress + info.RegionSize;
    }

    fault = probe_read(base);
    printf("%s stack barrier read at %p: %s (code %08lx)\n", who, (void *)base,
           fault ? "faulted" : "SILENT SUCCESS", fault);
}

static DWORD WINAPI worker(void *parameter)
{
    (void)parameter;
    describe_stack("worker");
    return 0;
}

int main(void)
{
    MEMORY_BASIC_INFORMATION info;
    char *address = NULL;
    unsigned int reported = 0;
    unsigned int steps = 0;
    PVOID handler;
    HANDLE thread;

    setvbuf(stdout, NULL, _IONBF, 0);
    handler = AddVectoredExceptionHandler(1, probe_handler);
    if (!handler)
        return 1;

    /* Passive inventory only: probing reads of foreign inaccessible regions can
     * disturb emulator-internal bookkeeping, so reads stay confined to this
     * program's own stack barriers below. */
    while ((uintptr_t)address < 0x7fffffff0000ull && reported < 64 && steps++ < 65536)
    {
        if (!VirtualQuery(address, &info, sizeof(info)) || !info.RegionSize)
            break;
        if (info.State == MEM_COMMIT &&
            (info.Protect == PAGE_NOACCESS || (info.Protect & PAGE_GUARD)))
        {
            MEMORY_BASIC_INFORMATION before, after;
            char *prev = (char *)info.BaseAddress - 1;
            char *next = (char *)info.BaseAddress + info.RegionSize;

            printf("inaccessible region %p+%08zx protect=%08lx alloc=%p\n", info.BaseAddress,
                   (size_t)info.RegionSize, info.Protect, info.AllocationBase);
            if (prev > (char *)info.AllocationBase && VirtualQuery(prev, &before, sizeof(before)))
                printf("  below: %p+%08zx state=%08lx protect=%08lx\n", before.BaseAddress,
                       (size_t)before.RegionSize, before.State, before.Protect);
            if (VirtualQuery(next, &after, sizeof(after)) &&
                after.AllocationBase == info.AllocationBase)
                printf("  above: %p+%08zx state=%08lx protect=%08lx\n", after.BaseAddress,
                       (size_t)after.RegionSize, after.State, after.Protect);
            reported++;
        }
        address = (char *)info.BaseAddress + info.RegionSize;
    }
    printf("inventory: %u committed inaccessible regions\n", reported);

    describe_stack("main");
    thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    if (!thread)
        return 2;
    if (WaitForSingleObject(thread, 30000) != WAIT_OBJECT_0)
        return 3;
    CloseHandle(thread);

    RemoveVectoredExceptionHandler(handler);
    puts("cpu-001 noaccess inventory done");
    return 0;
}
