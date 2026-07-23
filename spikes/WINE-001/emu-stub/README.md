# ARM64EC emulator stub (`xtajit64.dll`)

**Author:** Tim Isaev
**Purpose:** SPIKE-WINE-001 gate 3 — prove the Wine ARM64EC loader→emulator
handshake on macOS without the real x86-64 JIT (FEX, which is founder-integrated
and subject to the FEX in-tree no-AI-code policy).

Wine's EC ntdll loads the DLL named by
`HKLM\Software\Microsoft\Wow64\amd64` (default `xtajit64.dll`) from `system32`,
then `arm64ec_process_init()` resolves the exports declared in
`stub_emulator.def` and calls `ProcessInit()` → `ThreadInit()` →
`BeginSimulation()`. This stub implements that ABI: lifecycle/notification hooks
succeed as no-ops, and `BeginSimulation()` logs a marker and `ExitProcess(0)` at
the point where the real emulator would begin translating guest x64.

## Build

```sh
TC=…/llvm-mingw-20260616-ucrt-macos-universal/bin
$TC/arm64ec-w64-mingw32-clang -shared -o xtajit64.dll \
    stub_emulator.c stub_emulator.def -O2
```

Produces a PE32+ ARM64EC DLL (`file` reports "x86-64" — correct: ARM64EC carries
the AMD64 machine type). Verify exports with `llvm-objdump -p xtajit64.dll`.

## Install & test

```sh
cp xtajit64.dll "$WINEPREFIX/drive_c/windows/system32/xtajit64.dll"
WINEBOOTSTRAPMODE=1 wine C:\\some-x64-console.exe
```

Look for `alloy-emu-stub: ProcessInit …` and `alloy-emu-stub: BeginSimulation …`
in the output — those confirm the loader reached the emulator hand-off.

## Status (23 July 2026)

The x64 guest PE and this stub both **load** under the EC hybrid Wine build
(`work/build-2`), but execution is blocked earlier, at image mapping: setting
`PROT_EXEC` on the guest/EC code sections returns `EACCES` (see
`../results/2026-07-23-05-gate3-arm64ec-groundwork.md`). So the stub's
`ProcessInit`/`BeginSimulation` markers are not reached yet — the blocker is a
macOS W^X / `max_protection` issue in the cross-architecture mapping path, not in
this stub.
