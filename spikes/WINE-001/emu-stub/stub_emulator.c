/*
 * Alloy ARM64EC emulator stub ("xtajit64.dll" replacement)
 * Author: Tim Isaev
 *
 * PURPOSE (SPIKE-WINE-001 gate 3): prove the Wine ARM64EC loader plumbing on
 * macOS end-to-end WITHOUT the real x86-64 JIT. Wine's EC ntdll loads the DLL
 * named by HKLM\Software\Microsoft\Wow64\amd64 (default xtajit64.dll), resolves
 * the BTCpu64 and lifecycle exports via arm64ec_process_init(), then calls
 * ProcessInit() and ThreadInit() and finally BeginSimulation() to start guest
 * x64 execution. This stub implements that ABI so we can confirm every step up
 * to the emulator hand-off succeeds; BeginSimulation() reports and exits cleanly
 * instead of translating x64 (that is FEX's job - founder-integrated, and
 * subject to the FEX in-tree no-AI-code policy, so it is deliberately NOT here).
 *
 * This file is Alloy-authored test scaffolding, not a FEX contribution.
 */

#include <windows.h>
#include <winternl.h>
#include <stdio.h>

#ifndef STATUS_SUCCESS
#define STATUS_SUCCESS ((NTSTATUS)0)
#endif

/* forward-declared here to avoid pulling private Wine headers; matches the
 * ARM64_NT_CONTEXT arg only by pointer, which the stub never dereferences. */
typedef struct _ARM64_NT_CONTEXT ARM64_NT_CONTEXT;

/* NT internal, absent from the mingw SDK headers; only the first fields matter */
typedef struct _SYSTEM_CPU_INFORMATION {
    USHORT ProcessorArchitecture;
    USHORT ProcessorLevel;
    USHORT ProcessorRevision;
    USHORT MaximumProcessors;
    ULONG  ProcessorFeatureBits;
} SYSTEM_CPU_INFORMATION;

static void emu_log(const char *msg)
{
    /* goes to the Wine debug stream / stderr of the host process */
    fprintf(stderr, "alloy-emu-stub: %s\n", msg);
    fflush(stderr);
}

/* ---- lifecycle: called during arm64ec_process_init() ---- */

NTSTATUS WINAPI ProcessInit(void)
{
    emu_log("ProcessInit: EC loader reached the emulator; init OK");
    return STATUS_SUCCESS;
}

NTSTATUS WINAPI ThreadInit(void)
{
    return STATUS_SUCCESS;
}

void WINAPI ProcessTerm(HANDLE h, BOOL b, NTSTATUS s)
{
    (void)h; (void)b; (void)s;
}

void WINAPI ThreadTerm(HANDLE h, LONG l)
{
    (void)h; (void)l;
}

/* ---- the hand-off point: where the real JIT would start running x64 ---- */

void WINAPI BeginSimulation(void)
{
    emu_log("BeginSimulation: guest x64 entry reached - stub cannot translate x86-64.");
    emu_log("Plumbing proven; real execution requires the FEX emulator (founder-integrated).");
    /* exit cleanly so the harness records a deterministic, non-crashing result */
    ExitProcess(0);
}

/* ---- processor feature model ---- */

BOOLEAN WINAPI BTCpu64IsProcessorFeaturePresent(UINT feature)
{
    /* advertise nothing; the loader records these into emulated_processor_features */
    (void)feature;
    return FALSE;
}

void WINAPI UpdateProcessorInformation(SYSTEM_CPU_INFORMATION *info)
{
    if (info)
    {
        info->ProcessorArchitecture = PROCESSOR_ARCHITECTURE_AMD64;
        info->ProcessorLevel = 0;
        info->ProcessorRevision = 0;
    }
}

/* ---- cache / memory notifications: no-ops for the stub ---- */

void WINAPI BTCpu64FlushInstructionCache(const void *addr, SIZE_T len) { (void)addr; (void)len; }
void WINAPI FlushInstructionCacheHeavy(const void *addr, SIZE_T len) { (void)addr; (void)len; }
void WINAPI BTCpu64NotifyMemoryDirty(void *addr, SIZE_T len) { (void)addr; (void)len; }
void WINAPI BTCpu64NotifyReadFile(HANDLE h, void *addr, SIZE_T len, BOOL b, NTSTATUS s)
{ (void)h; (void)addr; (void)len; (void)b; (void)s; }
NTSTATUS WINAPI NotifyMapViewOfSection(void *a, void *b, void *c, SIZE_T d, ULONG e, ULONG f)
{ (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; return STATUS_SUCCESS; }
void WINAPI NotifyMemoryAlloc(void *a, SIZE_T b, ULONG c, ULONG d, BOOL e, NTSTATUS f)
{ (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; }
void WINAPI NotifyMemoryFree(void *a, SIZE_T b, ULONG c, BOOL d, NTSTATUS e)
{ (void)a; (void)b; (void)c; (void)d; (void)e; }
void WINAPI NotifyMemoryProtect(void *a, SIZE_T b, ULONG c, BOOL d, NTSTATUS e)
{ (void)a; (void)b; (void)c; (void)d; (void)e; }
void WINAPI NotifyUnmapViewOfSection(void *a, BOOL b, NTSTATUS c)
{ (void)a; (void)b; (void)c; }
void WINAPI ResetToConsistentState(EXCEPTION_RECORD *r, CONTEXT *c, ARM64_NT_CONTEXT *a)
{ (void)r; (void)c; (void)a; }

/* ---- ARM64<->x64 dispatch trio (resolved by name in arm64ec_process_init) ----
 * Real thunks perform the ABI transition; the stub only needs them to exist so
 * export resolution succeeds. They must never actually run for the init proof. */

void WINAPI ExitToX64(void) { emu_log("ExitToX64 (stub)"); }
void WINAPI DispatchJump(void) { emu_log("DispatchJump (stub)"); }
void WINAPI RetToEntryThunk(void) { emu_log("RetToEntryThunk (stub)"); }
