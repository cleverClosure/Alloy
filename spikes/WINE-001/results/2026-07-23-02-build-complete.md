# WINE-001 result 02 — Wine 11.13 builds complete on macOS/ARM64; loader launch is the frontier

**Author:** Timur Isaev
**Date:** 23 July 2026
**Wine revision:** 5bb70f2 (= Wine 11.13 per wineserver)

## Outcome

`make -j8` runs to **"Wine build complete"** — unix side (Mach-O arm64) and PE side
(aarch64-windows, llvm-mingw) both build. Functional check: `server/wineserver --version`
prints **"Wine 11.13"** and exits 0.

**Frontier:** `loader/wine --version` is SIGKILLed (exit 137) before producing output —
sandboxed and unsandboxed alike. The binary is a well-formed Mach-O arm64 with an ad-hoc
linker signature. Working hypothesis (known Apple Silicon Wine pattern): the loader needs
re-signing with entitlements (JIT/unsigned-executable-memory allowances, à la
CrossOver/Whisky distribution practice) and/or trips AMFI via its address-space reservation
segments. Gate 2 starts here: capture the kill reason from the unified log, apply an
entitlements re-sign, retest, and fold the finding into the signing plan
(ADR-0010's Developer ID + notarization model expects exactly this class of work).

## Recipe (reproducible, toolchain proof closed)

deps: Homebrew bison 3.8.2 (PATH-prepended; Apple's 2.3 too old), freetype, gnutls;
llvm-mingw 20260616 on PATH. `configure --with-mingw --without-x`, `make -j8`.
21 optional deps absent by choice at this stage (MoltenVK/Vulkan among them — deferred).

## Notes

- Build-machine reality check on the 16 GB floor: Wine `-j8` plus a concurrent FEX `-j4`
  ran to completion without OOM — dev-machine viability confirmed for spike-scale work.
- ARM64EC hybrid archs (`--enable-archs=arm64ec,aarch64,i386`) remain gate 3, attempted once
  the plain-ARM64 loader boots a prefix (gate 2 exit).
