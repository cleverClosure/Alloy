# ARM64EC emulator stub (`xtajit64.dll`)

**Author:** Timur Isaev
**Purpose:** SPIKE-WINE-001 gate 3 — prove the Wine ARM64EC loader→emulator
handshake on macOS without the real x86-64 JIT (FEX, which is founder-integrated
and subject to the FEX in-tree no-AI-code policy).

Wine's EC ntdll loads the DLL named by
`HKLM\Software\Microsoft\Wow64\amd64` (default `xtajit64.dll`), then
`arm64ec_process_init()` resolves the exports declared in
`stub_emulator.def` and calls `ProcessInit()` → `ThreadInit()`, and the first
transfer into x64 code (a TLS callback or the exe entry point) reaches the
dispatch trio. This stub implements that ABI: lifecycle/notification hooks
succeed as no-ops, and each of `ExitToX64`/`DispatchJump`/`RetToEntryThunk`
logs a hand-off marker and exits 0 at the exact point where the real emulator
would begin translating guest x64. (The real thunks never return, so the stub
must not either — returning corrupts the transition SP.)

## Build — three constraints, all load-bearing

```sh
TC=…/llvm-mingw-20260616-ucrt-macos-universal/bin
$TC/arm64ec-w64-mingw32-clang -shared -nostdlib -O2 \
    -Wl,--file-alignment,0x10000,--section-alignment,0x10000 \
    -o xtajit64.dll stub_emulator.c stub_emulator.def -lmingwex -lntdll
```

1. **`-nostdlib` (imports = ntdll only).** The CRT pulls in
   ucrtbase→kernel32→kernelbase as *dependencies of the emulator*, which then
   load — and get their `__os_arm64x_*` hybrid-metadata slots stamped — before
   `arm64ec_process_init` resolves the dispatch pointers. Every exit thunk in
   kernel32 is then a jump to NULL. Real xtajit64 imports only ntdll.
   `-lmingwex` provides the EC glue objects (`__icall_helper_arm64ec`,
   metadata slot definitions) without CRT imports; `DllMainCRTStartup` is
   defined in the stub.
2. **64K section alignment.** With 4K sections, `.rdata` (CHPE metadata, IAT)
   shares a 16K host page with `.text`/`.hexpthk`, and making it writable
   would need RWX — denied on macOS; the loader's unchecked metadata write
   then faults before init completes.
3. **ntdll-only runtime calls** (`DbgPrint`, `RtlExitUserProcess`).
   `ProcessInit` runs before any DLL initializers — CRT stdio state does not
   exist yet.

Produces a PE32+ ARM64EC DLL (`file` reports "x86-64" — correct: ARM64EC
carries the AMD64 machine type). Verify with `llvm-readobj --coff-exports
--coff-imports xtajit64.dll`: 21 exports, imports ntdll.dll only.

`FEXWineLogSink` is a writable data export used to validate Wine's optional
native logging callback injection before the matching founder-authored hook is
added to FEX. `ProcessInit` calls the injected pointer and emits
`alloy-emu-stub: injected FEX log sink reached`.

## Install & test

```sh
cp xtajit64.dll "$WINEPREFIX/drive_c/windows/system32/xtajit64.dll"
WINEDLLOVERRIDES=xtajit64=n WINEDEBUG=warn+debugstr wine C:\\x64min.exe
```

- `WINEDLLOVERRIDES=xtajit64=n` — Wine ships its own (non-functional) builtin
  xtajit64; running from the build tree, builtins beat the system32 file
  unless the load order forces native.
- `WINEDEBUG=warn+debugstr` — the markers go through `DbgPrint`, which Wine
  emits at warn level on the `debugstr` channel (invisible by default).

Expected:

```text
alloy-emu-stub: ProcessInit: EC loader reached the emulator; init OK
alloy-emu-stub: injected FEX log sink reached
alloy-emu-stub: ExitToX64: x64 code transfer requested - Wine-side plumbing proven; exiting (stub).
(exit 0)
```

Guest sources live in `../testcases/` (`x64min.c` — freestanding, no imports;
`x64hello.c` — full CRT, TLS callback, the shape of a real Windows binary).

## Status (23 July 2026)

**Wine-side gate 3 proven** with this stub: both guests reach the hand-off with
exit 0 and no faults. See `../results/2026-07-23-06-gate3-wine-side-proven.md`
for the full kill-chain (RWX/16K-page root cause and the three compounding
defects). The only remaining gate-3 work is the FEX Darwin port and swapping
`libarm64ecfex.dll` in for this stub (founder-only; the Wine-side dispatch-trio
redirection fix already covers FEX's lld-built exports).
