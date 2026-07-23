# CPU-001 result 03 — libarm64ecfex.dll builds on macOS (gate 1 closed)

**Author:** Tim Isaev
**Date:** 23 July 2026
**FEX revision:** 0589d9b · **Toolchain:** llvm-mingw 20260616 release binaries

## Outcome

`ninja arm64ecfex` with **upstream's canonical CI flags** (from
`.github/workflows/wine_build/action.yml`) produces
`Bin/libarm64ecfex.dll` — **4.9 MB PE32+ DLL — on a macOS host with zero FEX source changes.**
`file` reports "x86-64": correct for ARM64EC (EC binaries carry the AMD64 machine type by design).

Canonical flag set (added to result-02's invocation): `-DENABLE_LTO=False
-DENABLE_ASSERTIONS=False -DENABLE_JEMALLOC_GLIBC_ALLOC=False -DBUILD_TESTING=False
-DTUNE_ARCH=generic` (and `BUILD_TESTING`, not `BUILD_TESTS` — the misnamed flag in earlier
attempts silently left unit tests enabled).

Autopsy of the failed first link (result 02's "next"): flag drift, not platform. With tests
enabled and canonical flags absent, the link pulled EC-mangled libc++/EC-ABI symbols
(`#SyncThreadContext`, `std::__1::*` as EC symbols) that the canonical configuration does not.
Note for later: upstream CI self-builds llvm-mingw on a self-hosted ARM64 runner; our *release*
llvm-mingw 20260616 sufficed for the DLL target.

## Gate 1 verdict

**The buildable unit MGCR needs exists on macOS.** FEX's Wine-facing artifact set is
host-OS-independent PE (this DLL) plus a ~175-line Linux unix-side bridge. Remaining port
surface for the Wine-hosted model: a Darwin UnixLib variant, and the runtime behaviors
(Mach exceptions, MAP_JIT/W^X, 16 KB pages) that only manifest under Wine at execution time.

## Next (gate 2+)

1. WINE-001 gate 2 first (wine loader launch on macOS — currently SIGKILLed pre-main;
   entitlement re-sign hypothesis), since FEX-DLL runtime testing needs a bootable Wine.
2. Founder-authored Darwin UnixLib exploration (drop `librt`, Wine-on-Mac unixlib format).
3. Upstream engagement (policy-compatible, non-code): pkg_resources issue report;
   Darwin-host interest question.
