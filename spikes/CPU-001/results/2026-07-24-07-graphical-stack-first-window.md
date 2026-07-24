# CPU-001 result 07 — graphical stack live: first x64 guest window through winemac.drv

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `61bf569` (build-2, unmodified) · **FEX:** darwin-teb
`0a1c3d39…` · **Hardware:** MacBook Pro M2 Pro, 16 GB, macOS 26.5

## Outcome

**An x64 Windows GUI program, translated by FEX, opens a real on-screen window through
winemac.drv on native ARM64 macOS.** `testcases/win_smoke.c` (self-verifying: paints the
client area RGB(200,30,40) on WM_PAINT, then reads pixels back through GDI) exits 0:

```text
window created: 0000000000010058 visible=1
readback: center=281ec8 corner=281ec8 expected=281ec8 paints=1
cpu-001 window/GDI smoke ok
```

A `WINEDEBUG=trace+macdrv` run shows 339 macdrv trace lines including
`create_cocoa_window` for the test window and the desktop — the full pipeline
guest x64 → FEX JIT → user32/win32u → winemac.drv → Cocoa/WindowServer is exercised, not
just GDI bookkeeping.

## The fix was one environment variable

Gate 2's follow-up note ("full graphical boot needs FreeType+winemac.drv build") was
stale: **build-2 already contains both** — configure found brew freetype 2.14.3
(`SONAME libfreetype.6.dylib`) and `dlls/winemac.drv` builds for both PE architectures,
fonts included. The perpetual runtime warning ("Wine cannot find the FreeType font
library") was a **dlopen search-path failure**: Wine resolves the bare soname at runtime,
and `/opt/homebrew/lib` is not on the default dlopen path.

```sh
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib   # add to every graphical run
```

With it set, a fresh graphical prefix boots with **zero FreeType warnings** (exit 0), and
the shear census stays noaccess-quiet through boot and the window test.

## Runbook additions

- Graphical prefix: boot with `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib`; FEX selected
  the usual way (`select-fex.reg` + `libarm64ecfex.dll` into system32).
- GUI guest tests need explicit `-lgdi32 -luser32` with llvm-mingw.
- Probe prefix for graphics: `work/fex-runtime-probe/prefix-gui`; logs `gui-boot.log`,
  `win-smoke-1.log`, `win-smoke-macdrv.log`.
- Open production question (Phase 1, not spike-blocking): ship-time linkage for freetype —
  bundle a pinned dylib or add an rpath — instead of relying on the caller's environment.

## What this unblocks

GFX-001 can start: winemac.drv gives windows, surfaces, and the Metal layer hosting that
DXMT (D3D11 provider) and later Metal12 need. The next concrete step is a pinned DXMT
build targeted at this EC Wine (ARM64EC PE + arm64 unix side) and a first D3D11 clear/
triangle scene under FEX.
