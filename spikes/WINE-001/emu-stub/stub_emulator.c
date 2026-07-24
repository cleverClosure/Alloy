/*
 * Alloy ARM64EC emulator stub ("xtajit64.dll" replacement)
 * Author: Timur Isaev
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

#ifndef STATUS_SUCCESS
#define STATUS_SUCCESS ((NTSTATUS)0)
#endif

/* forward-declared here to avoid pulling private Wine headers; matches the
 * ARM64_NT_CONTEXT arg only by pointer, which the stub never dereferences. */
typedef struct _ARM64_NT_CONTEXT ARM64_NT_CONTEXT;

/* NT internal, absent from the mingw SDK headers; only the first fields matter */
typedef struct _SYSTEM_CPU_INFORMATION
{
    USHORT ProcessorArchitecture;
    USHORT ProcessorLevel;
    USHORT ProcessorRevision;
    USHORT MaximumProcessors;
    ULONG ProcessorFeatureBits;
} SYSTEM_CPU_INFORMATION;

/* ntdll-only logging/exit: ProcessInit runs during arm64ec_process_init,
 * before any DLL initializers (ucrtbase CRT state is not set up yet), so
 * stdio would fault.  DbgPrint reaches Wine's debug stream at any stage. */
ULONG WINAPIV DbgPrint(const char *fmt, ...);
DECLSPEC_NORETURN void WINAPI RtlExitUserProcess(NTSTATUS status);

typedef void(__cdecl *FEX_LOG_SINK)(const char *message);
FEX_LOG_SINK FEXWineLogSink;

static void emu_log(const char *msg)
{
    DbgPrint("alloy-emu-stub: %s\n", msg);
}

/* Built with -nostdlib: the emulator DLL must import ONLY ntdll.  Linking the
 * mingw CRT pulls in ucrtbase -> kernel32 -> kernelbase as dependencies of
 * xtajit64.dll, which the EC loader then loads (and stamps hybrid metadata
 * for) BEFORE arm64ec_process_init resolves the dispatch trio - leaving their
 * __os_arm64x_* slots NULL and every exit thunk jumping to 0.  Real xtajit64
 * imports only ntdll for the same reason. */
BOOL WINAPI DllMainCRTStartup(HINSTANCE inst, DWORD reason, void *reserved)
{
    (void)inst;
    (void)reason;
    (void)reserved;
    return TRUE;
}

/* ---- lifecycle: called during arm64ec_process_init() ---- */

NTSTATUS WINAPI ProcessInit(void)
{
    emu_log("ProcessInit: EC loader reached the emulator; init OK");
    if (FEXWineLogSink)
        FEXWineLogSink("alloy-emu-stub: injected FEX log sink reached\n");
    else
        emu_log("ProcessInit: injected FEX log sink is missing");
    return STATUS_SUCCESS;
}

NTSTATUS WINAPI ThreadInit(void)
{
    return STATUS_SUCCESS;
}

void WINAPI ProcessTerm(HANDLE h, BOOL b, NTSTATUS s)
{
    (void)h;
    (void)b;
    (void)s;
}

void WINAPI ThreadTerm(HANDLE h, LONG l)
{
    (void)h;
    (void)l;
}

/* ---- the hand-off point: where the real JIT would start running x64 ---- */

void WINAPI BeginSimulation(void)
{
    emu_log("BeginSimulation: guest x64 entry reached - stub cannot translate x86-64.");
    emu_log("Plumbing proven; real execution requires the FEX emulator (founder-integrated).");
    /* exit cleanly so the harness records a deterministic, non-crashing result */
    RtlExitUserProcess(0);
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

void WINAPI BTCpu64FlushInstructionCache(const void *addr, SIZE_T len)
{
    (void)addr;
    (void)len;
}
void WINAPI FlushInstructionCacheHeavy(const void *addr, SIZE_T len)
{
    (void)addr;
    (void)len;
}
void WINAPI BTCpu64NotifyMemoryDirty(void *addr, SIZE_T len)
{
    (void)addr;
    (void)len;
}
void WINAPI BTCpu64NotifyReadFile(HANDLE h, void *addr, SIZE_T len, BOOL b, NTSTATUS s)
{
    (void)h;
    (void)addr;
    (void)len;
    (void)b;
    (void)s;
}
NTSTATUS WINAPI NotifyMapViewOfSection(void *a, void *b, void *c, SIZE_T d, ULONG e, ULONG f)
{
    (void)a;
    (void)b;
    (void)c;
    (void)d;
    (void)e;
    (void)f;
    return STATUS_SUCCESS;
}
void WINAPI NotifyMemoryAlloc(void *a, SIZE_T b, ULONG c, ULONG d, BOOL e, NTSTATUS f)
{
    (void)a;
    (void)b;
    (void)c;
    (void)d;
    (void)e;
    (void)f;
}
void WINAPI NotifyMemoryFree(void *a, SIZE_T b, ULONG c, BOOL d, NTSTATUS e)
{
    (void)a;
    (void)b;
    (void)c;
    (void)d;
    (void)e;
}
void WINAPI NotifyMemoryProtect(void *a, SIZE_T b, ULONG c, BOOL d, NTSTATUS e)
{
    (void)a;
    (void)b;
    (void)c;
    (void)d;
    (void)e;
}
void WINAPI NotifyUnmapViewOfSection(void *a, BOOL b, NTSTATUS c)
{
    (void)a;
    (void)b;
    (void)c;
}
void WINAPI ResetToConsistentState(EXCEPTION_RECORD *r, CONTEXT *c, ARM64_NT_CONTEXT *a)
{
    (void)r;
    (void)c;
    (void)a;
}

/* ---- ARM64<->x64 dispatch trio (resolved by name in arm64ec_process_init) ----
 * Real thunks transfer control INTO guest x64 code and never return normally.
 * Returning would leave the transition state (including SP adjustments) broken,
 * so each stub logs the hand-off marker and terminates cleanly: reaching any of
 * these means the loader completed the native side and requested x64 execution
 * (e.g. a TLS callback or the exe entry), which only a real emulator can run. */

void WINAPI ExitToX64(void)
{
    emu_log("ExitToX64: x64 code transfer requested - Wine-side plumbing proven; exiting (stub).");
    RtlExitUserProcess(0);
}

void WINAPI DispatchJump(void)
{
    emu_log(
        "DispatchJump: x64 code transfer requested - Wine-side plumbing proven; exiting (stub).");
    RtlExitUserProcess(0);
}

void WINAPI RetToEntryThunk(void)
{
    emu_log(
        "RetToEntryThunk: return into x64 requested - Wine-side plumbing proven; exiting (stub).");
    RtlExitUserProcess(0);
}
