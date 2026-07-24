# GFX-001 result 01 — DXMT builds clean for ARM64EC on macOS (gate 1 closed)

**Author:** Tim Isaev
**Date:** 24 July 2026
**DXMT revision:** e520fea (main, LGPL, CodeWeavers) · **Toolchain:** pinned llvm-mingw
20260616 (arm64ec target) + brew llvm@15 15.0.7 (native) + meson/ninja ·
**Wine headers:** WINE-001 build-2

## Outcome

**DXMT builds completely for this stack with zero source changes: 161/161 targets, first
attempt.** Artifact inventory:

| Artifact | Type | Role |
| --- | --- | --- |
| `src/d3d11/d3d11.dll`, `src/d3d10/*`, `src/dxgi/dxgi.dll` | PE32+ ARM64EC (x86-64 machine type, EC convention) | Guest-facing D3D10/11/DXGI provider |
| `src/winemetal/winemetal.dll` | PE ARM64EC | PE side of the Metal bridge |
| `src/winemetal/unix/winemetal.so` | Mach-O arm64 | Unix side: the only code that touches Metal |
| `src/airconv/darwin/airconv` + `libairconv.a` | Mach-O arm64 | DXBC → AIR shader translator (native) |

Upstream ships `build-arm64ec.txt` — DXMT targets ARM64EC out of the box, and our pinned
llvm-mingw provides the full `arm64ec-w64-mingw32-*` alias set the cross file expects.
Configure needs exactly two options: `-Dwine_build_path` (build-2; provides ntdll/dbghelp
import libs and the unixlib interface) and `-Dnative_llvm_path`.

## Fetch and provenance

Executed per the standing MANIFEST.toml procedure: shallow clone at `e520fea` with
`src/d3d12/` **deleted in the same command, before any tree inspection** (ADR-0012
Metal12 clean-room exclusion; PROVENANCE.log entry 2026-07-24). The meson option
`enable_d3d12` is off by default, so the quarantined checkout configures cleanly.
`fetch-deps.sh` now performs the guarded fetch itself for reproducibility. Checkout
LICENSE confirms LGPL-2.1+ (CodeWeavers copyright) — matches the legal findings row.
Submodules: nvapi (option off), DirectX-Headers (ADR-0012 approved input).

## The one dependency finding

`airconv` requires **native LLVM 15 specifically** (`native_llvm_path`, upstream default
`/usr/local/opt/llvm@15`): AIR is Apple's frozen LLVM bitcode dialect, so the emitting
LLVM's version is pinned. Resolution: `brew install llvm@15` still pours a bottle
(15.0.7, 1.1 GB) on macOS 26 — recorded as a bootstrap dependency in MANIFEST.toml.
DXMT's own CI source-builds `llvmorg-15.0.7` instead; that is the fallback if the brew
bottle ever disappears. One benign link warning (libunwind reexport path) — cosmetic.

Also recorded in `fetch-deps.sh`: rerunning the fetch script rewrites lock lines from
checkout HEADs, and the wine checkout now lives on the alloy fork branch — the wine lock
line preserves the original upstream pin only if the script is not rerun blindly.

## Gate 2 plan (first light) — open questions

1. **Install layout**: place `d3d11.dll`/`dxgi.dll`/`winemetal.dll` into the prefix (or
   as build-tree overrides) for the x64 guest to load under FEX; `winemetal.so` must land
   where Wine's unixlib loader finds it (build-2 dll path or `WINEDLLPATH`).
   `wine_builtin_dll=true` builds them as Wine builtins — decide override vs builtin
   placement.
2. **Test guest**: minimal x64 D3D11 program — device + swapchain on the win_smoke window
   (CPU-001 result 07 stack), clear to a known color, CPU readback via staging texture.
   Self-verifying like the existing corpus.
3. Census note: watch for DXMT-created NOACCESS/guard patterns under the shear census —
   provider code is new territory for the noaccess class.
