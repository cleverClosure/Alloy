# WINE-001 result 01 — upstream Wine configures clean on macOS/ARM64

**Author:** Timur Isaev
**Date:** 23 July 2026
**Wine revision:** 5bb70f2 (master, shallow) · **Host:** M2 Pro 16 GB, macOS 26.5.2

## Gate 1 (toolchain proof) — configure stage

`configure --with-mingw --without-x` with `PATH` prepending Homebrew bison 3.8.2 (Apple's 2.3 is
below Wine's minimum) and llvm-mingw 20260616: **completes first try** — "Finished. Do 'make'."
21 optional "not found" items (Vulkan/MoltenVK dev files among them — expected; MoltenVK arrives
via Alloy's own bundling later, and the Wine build finds it via `--with-vulkan` when we choose).
No X11 by design (`--without-x`); Wine's macOS driver is the target presentation path.

In-tree policy check before any patching: Wine carries no CLAUDE.md/AGENTS.md/CONTRIBUTING —
no in-tree AI-contribution policy (contrast FEX, CPU-001 result 01 §3). WineHQ submission rules
are checked out-of-tree before any upstream submission; Alloy's baseline compliance model is
fork-and-publish per doc 18 regardless.

## Build stage

`make -j8` launched against the same environment; outcome lands in result 02. Deliverable on
success: the reproducible recipe (deps: bison≥3.8, llvm-mingw, freetype/gnutls via Homebrew;
flags as above) promoted into a committed build script.

## Observations for later gates

- Default archs on this host: ARM64 unix side + aarch64 PE. The ARM64EC hybrid
  (`--enable-archs=arm64ec,aarch64,i386` with llvm-mingw's `arm64ec-w64-mingw32`) is the gate-3
  configuration, attempted after the baseline build proves out.
- FEX's `wine_builtin.bin` + `UnixLib` (see CPU-001 result 02) indicate upstream FEX already
  speaks Wine's emulator-DLL interface — gate 3's integration surface is real and maintained.
