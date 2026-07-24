# CPU-001 FEX log-sink handoff

**Author:** Timur Isaev  
**Scope:** Founder-authored FEX hook required to unblock item #24 attribution  
**Wine contract:** `third_party/src/wine` branch `alloy/spike-wine-001`

## Proven Wine-side contract

Wine now looks for an optional ARM64EC emulator data export named
`FEXWineLogSink` before calling `ProcessInit`. When present, the export must be
a writable, initially null function-pointer slot with this ABI:

- C calling convention;
- one `const char *` argument;
- null-terminated message;
- no return value.

Wine writes a native ARM64EC callback into the slot. The callback forwards the
message to `__wine_dbg_output`. Absence of the export is intentionally a no-op
so stock emulators and the current FEX build remain compatible.

The ABI and timing were validated with the first-party emulator stub:

1. the PE contained `FEXWineLogSink` as a data export;
2. Wine found the writable slot before `ProcessInit`;
3. `ProcessInit` called the injected pointer;
4. the exact marker reached stderr;
5. the stub completed with exit 0.

## Founder-authored FEX work

The FEX change must remain founder-authored under `CONTRIBUTING.md`. Its
required behavior is deliberately small:

1. define the writable `FEXWineLogSink` slot in the ARM64EC module;
2. export it as data from `libarm64ecfex.dll`;
3. make the Windows logging initialization prefer the injected slot;
4. retain the existing file fallback when neither injected nor Wine-resolved
   output is usable;
5. do not alter exception-dispatch behavior in the logging commit.

Expected FEX touch points:

- `Source/Windows/ARM64EC/libarm64ecfex.def`;
- `Source/Windows/Common/Logging.h`;
- `Source/Windows/Common/Logging.cpp`.

## Bridge acceptance

Before adding new breadcrumbs:

1. rebuild `libarm64ecfex.dll`;
2. confirm `llvm-readobj --coff-exports` reports `FEXWineLogSink`;
3. run the existing green `seh_worker.exe`;
4. require at least the existing `Exception: Code:` and
   `Rethrowing onto guest stack` FEX messages on stderr;
5. confirm `seh_worker.exe` still exits 0.

Then use [`run-seh-multi-matrix.sh`](run-seh-multi-matrix.sh) for the four-mode
control capture. The first capture is expected to preserve item #24's current
failure; its purpose is to prove that breadcrumbs survive on both successful
and failing worker paths.

## First attribution breadcrumbs

Add only enough founder-authored instrumentation to compare the successful
first worker with the failing second worker:

- entry/exit around `SyncThreadContext`;
- entry/exit around `ProcessPendingCrossProcessEmulatorWork`;
- CPU-area pointer, thread-state pointer, `InSimulation`, suspend-doorbell
  value, guest `State.rip`, and guest stack pointer;
- entry and packed-context values in `RethrowGuestException`.

Every breadcrumb needs the Windows thread ID. Avoid allocation or locking in
the event payload beyond what the existing FEX logging path already performs.
Do not attempt a dispatch fix until one trace identifies the first divergent
state transition.
