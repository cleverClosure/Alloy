# WINE-001 gate 3 groundwork — ARM64EC hybrid build and the emulator interface

**Author:** Timur Isaev
**Date:** 23 July 2026
**Status:** in progress — EC hybrid Wine building; stub emulator ready; EC TEB fixes staged

## Goal

Gate 3 proves the **x86-64 guest** path: an x64 PE loaded through Wine's ARM64EC
loader, handed to a processor emulator. The real emulator is FEX
(`libarm64ecfex.dll`, already built in gate 1) — but wiring FEX to the Darwin host
requires FEX-tree code, which is **founder-authored only** (FEX in-tree policy bans
AI-generated contributions). So gate 3 is split:

- **Wine side (AI-assistable):** the EC hybrid build, the Darwin EC TEB fixes, and a
  *stub* emulator that exercises the loader→emulator handshake.
- **FEX side (founder-only):** the Darwin `FEXUnixLib` port and real x64 translation.

This note records the Wine-side groundwork so the founder can drop FEX in behind a
proven loader path.

## Build

`build-2` configured with `--with-mingw --without-x --enable-archs=arm64ec,aarch64`
(vs `build-1`'s `aarch64` only). The `arm64ec-w64-mingw32` toolchain is present and
produces `coff-arm64ec` objects; configure and the C99/link probes pass. Full EC-mode
Wine build in progress (thousands of objects across both arches).

## Emulator interface (from `dlls/ntdll/loader.c` + `signal_arm64ec.c`)

Wine's EC ntdll finds the emulator by reading
`HKLM\Software\Microsoft\Wow64\amd64` (default `xtajit64.dll`), loads it from
`system32`, then `arm64ec_process_init()` resolves these exports:

- **Dispatch trio** (ARM64↔x64 transition thunks): `ExitToX64`, `DispatchJump`,
  `RetToEntryThunk`.
- **Lifecycle:** `ProcessInit` (→NTSTATUS), `ThreadInit` (→NTSTATUS), `ProcessTerm`,
  `ThreadTerm`, `BeginSimulation` (starts guest x64 execution).
- **Feature/CPU:** `BTCpu64IsProcessorFeaturePresent` (→BOOLEAN),
  `UpdateProcessorInformation`.
- **Cache/memory notifications:** `BTCpu64FlushInstructionCache`,
  `FlushInstructionCacheHeavy`, `BTCpu64NotifyMemoryDirty`, `BTCpu64NotifyReadFile`,
  `NotifyMapViewOfSection`, `NotifyMemoryAlloc`, `NotifyMemoryFree`,
  `NotifyMemoryProtect`, `NotifyUnmapViewOfSection`, `ResetToConsistentState`.

Init order: `ProcessInit()` → probe every processor feature → build the cross-process
work list → `ThreadInit()` → then guest execution via `BeginSimulation()`.

## Stub emulator (Alloy-authored, `work/emu-stub/`)

`stub_emulator.c` + `stub_emulator.def` compile with `arm64ec-w64-mingw32-clang` into
an ARM64EC `xtajit64.dll` (PE32+; `file` reports "x86-64" — correct for ARM64EC).
All 20 exports present (verified via `llvm-objdump -p`). Behavior:

- lifecycle/notification hooks return success / no-op;
- `BTCpu64IsProcessorFeaturePresent` advertises nothing;
- `BeginSimulation` logs "guest x64 entry reached" and `ExitProcess(0)` — a
  deterministic, non-crashing marker that the loader completed the whole handshake and
  reached the point where FEX would take over.

This isolates *Wine's EC plumbing* from *the JIT*: if a real x64 PE drives the loader
all the way to the stub's `BeginSimulation` message, the Wine side of gate 3 is proven
and the only remaining piece is FEX's Darwin port.

Source lives in `spikes/WINE-001/emu-stub/` (tracked); the built `xtajit64.dll` is an
artifact under `work/emu-stub/`.

## EC TEB fixes — applied

The native-ARM64 x18→TSD fix (commit `efd41b9`) already covers EC **C** code —
`NtCurrentTeb()` in `winnt.h` is guarded by `(defined(__aarch64__) || defined(__arm64ec__))`.
The **4 hand-written `[x18,#0x60]` (Peb via TEB) reads** in
`dlls/ntdll/signal_arm64ec.c` (KiUserCallbackDispatcher, `arm64x_check_call`, the
exception dispatch, DbgUiRemoteBreakin) now get the
`mrs xN, tpidrro_el0; ldr xN, [xN, #0x30]` treatment, so EC dispatch/exception paths
read the TEB from TSD slot 6 instead of the Darwin-clobbered x18. Zero `[x18` reads
remain in the file; the EC ntdll rebuilds clean.

Note: ARM64EC on Darwin is inherently more x18-sensitive than native ARM64 — the whole
EC ABI (and the emulator's register model) assumes x18=TEB. The 4 Wine sites are the
known in-tree reads; the FEX register model's x18 handling on Darwin is a founder
integration concern to validate against the real emulator.

## Test run — how far it gets, and the blocker

`work/build-2` (EC hybrid) with the JIT-loader flag patch (`configure.ac`'s aarch64
loader case, applied to the generated Makefile since a fresh `configure` predates the
autoconf regen) boots and installs an ARM64X ntdll (`coff-arm64x`, with `.hexpthk`
hybrid entry thunks and `.a64xrm` redirection metadata — a genuine EC-capable ntdll).
A minimal x86-64 console PE (`coff-x86-64`, built with `x86_64-w64-mingw32-clang`) was
run against a bootstrapped EC prefix with the stub installed. Observed:

- `C:\x64hello.exe` **loaded** at its preferred base `0x140000000` (native x64);
- `xtajit64.dll` (the stub) **loaded** at `0x6ffffd660000` (builtin);
- **blocked before `ProcessInit`**: `map_image_into_view` fails to set `0x60000020`
  (execute+read code) protection on the `.text`/`.hexpthk` sections of both the x64 exe
  and the EC stub — `mprotect(PROT_EXEC)` returns **errno 13 (EACCES)**.

So the loader recognises the x64 image and finds/loads the emulator, but the guest/EC
code can't be made executable. The stub's `ProcessInit`/`BeginSimulation` markers are
therefore not reached yet.

### Root cause — narrowed, not fully resolved

EACCES on `mprotect(PROT_EXEC)` means the region's Mach **max_protection** lacks
`VM_PROT_EXECUTE`. Confirmed facts:

- native-ARM64 `build-1` never hits this (reg.exe/cmd.exe run clean); it is specific to
  the **cross-arch** (x64/EC-on-arm64) image path. The `.text` there is mapped
  `MAP_PRIVATE | PROT_READ|PROT_WRITE` (WRITECOPY, for relocations) and then
  transitioned to `PROT_READ|PROT_EXEC`.
- it is **not** the reserved-area allocator: `reserve_area()` uses
  `mach_vm_map(..., cur=PROT_NONE, max=VM_PROT_ALL)`, so reservations *do* allow exec;
  and the x64 base `0x140000000` sits above the reserved ranges anyway.
- it is **not** JIT entitlements: signing the loader with
  `allow-jit`/`allow-unsigned-executable-memory`/`disable-executable-page-protection`
  changed nothing (and the adhoc build failed identically); a standalone program does
  RW-file→RX and reserve+`MAP_FIXED`+RX transitions on this machine **without** any
  entitlement. So the capability exists; Wine's process reaches the mapping in a state a
  simple repro doesn't reproduce.

Open: the exact source of the capped max_prot on Wine's cross-arch section mapping.
Next diagnostic is a live `mach_vm_region` dump of the failing region's max_protection
at the `mprotect` failure (was blocked this session by the hardened-runtime signature I
applied then reverted — rerun adhoc so lldb can attach). The `virtual.c` ERR at the
failure site was extended to print `errno`/`strerror` to aid this.

## Next actions (in order)

1. `mach_vm_region` the failing region → find what maps it with max_prot < exec; fix the
   cross-arch section mapping (Wine-side, AI-assistable) so `PROT_EXEC` is reachable.
2. Then the loader should reach the stub's `ProcessInit`/`BeginSimulation` markers →
   Wine-side gate 3 proven.
3. Founder: Darwin `FEXUnixLib` port + swap the stub for `libarm64ecfex.dll` → real
   x64 execution (CPU-001 gate 4).
