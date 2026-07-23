# CPU-001 result 02 — ARM64EC PE cross-configure succeeds on macOS unmodified

**Author:** Tim Isaev
**Date:** 23 July 2026
**FEX revision:** 0589d9b · **Toolchain:** llvm-mingw 20260616 (`arm64ec-w64-mingw32`)

## The reframe

`Source/Windows/` (ARM64EC, WOW64, UnixLib, `wine_builtin.bin`) is built **only under MINGW** —
FEX's Wine integration ships as **PE artifacts** (`libarm64ecfex.dll` and friends) that are
cross-compiled regardless of host OS, plus a ~175-line unix-side bridge
(`UnixLib/FEXUnixLib.cpp` → `libarm64ecfex.so`, currently Linux-only: links `librt`).
Alloy does not need FEX's Linux frontend (ELF loader / syscall emulation) at all. The port
therefore splits:

1. **PE side — possibly zero porting.** Cross-compiling PE is host-independent; the Darwin
   platform gate (result 01) never fires because the mingw toolchain file sets
   `CMAKE_SYSTEM_NAME Windows`.
2. **Unix side — small and explicit.** A Darwin build of the UnixLib bridge (drop `librt`,
   `.so`→ Wine-on-Mac's unix-lib format) plus whatever JIT/W^X/Mach-exception behavior only
   manifests at runtime under Wine on macOS.
3. **Runtime risk remains the real risk**: MAP_JIT/per-thread W^X, 16 KB host pages under 4 KB
   guest assumptions, Mach exception delivery through Wine — none of it exercised by building.

## Configure ladder (all environment-side; zero FEX source changes)

| # | Failure | Class | Resolution |
| --- | --- | --- | --- |
| 1 | `CMAKE_ASM_NASM_COMPILER` missing | host tool gap | `brew install nasm` (3.02) |
| 2 | `NeedDisabledSVE.py`: `No module named 'pkg_resources'` | upstream vs. Python ≥3.12 — would fail on modern Linux too; candidate upstream issue report | venv Python with `setuptools<81` on PATH |
| 3 | `aarch64_fit_native.py` reads `/proc/cpuinfo` (CMakeLists 491–511) | Linux-only host introspection, gated on `TUNE_CPU=native` | `-DTUNE_CPU=none` (documented cache var) |
| 4 | `IMPORTED_IMPLIB not set for fmt::fmt` | host-library contamination: `find_package(fmt QUIET)` found Homebrew's macOS fmt in a Windows cross build | `-DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE` → vendored `External/fmt` |

Working invocation (attempt 6, exit 0):

```
PATH="<venv-with-setuptools>/bin:<llvm-mingw>/bin:$PATH" \
cmake -S third_party/src/fex -B <build> -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=Data/CMake/toolchain_mingw.cmake \
  -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DBUILD_TESTS=False \
  -DTUNE_CPU=none -DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE
```

## Next

`ninja arm64ecfex` (in progress at time of writing — outcome in result 03). If the DLL links,
gate 1's build survey concludes: **the buildable unit exists on macOS**, and the spike's weight
shifts to SPIKE-WINE-001 integration (Wine loading `libarm64ecfex.dll` + a Darwin unix bridge)
and the runtime questions above. Candidate upstream engagements (non-code, policy-compatible):
issue report for pkg_resources; question on Darwin-host support interest.
