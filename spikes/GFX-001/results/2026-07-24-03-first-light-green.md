# GFX-001 result 03 — D3D11 first light GREEN: gate 2 closed

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `ddad4ac` · **DXMT:** e520fea (darwin-teb arm64ec build)
**Hardware:** M2 Pro, 16 GB, macOS 26.5

## Verdict

```text
stage: window created
stage: device created, feature level b000
adapter: Apple M2 Pro vendor=106b device=0000
stage: render target ready
readback: b=191 g=128 r=64 a=255 (expected 191 128 64 255)
stage: readback verified
stage: presented
gfx-001 d3d11 first light ok
```

`testcases/d3d11_smoke.c` self-verifies end-to-end: an x64 guest under FEX creates a
real DXMT D3D11 device on Metal, clears a swapchain backbuffer, and reads the exact
clear color back through a staging texture. **Every layer of the runtime thesis is now
live in one process: x64 → FEX (darwin-teb) → ARM64EC Wine → DXMT d3d11/dxgi →
winemetal unixlib → Metal.** Baseline corpus regression-checked green after both fork
changes (`x64hello 0, isa_smoke 0, jit_pages 7` — known shear — `win_smoke 0`).

## What stood between result 02 and green: five blockers, in order

1. **DXMT darwin-teb rebuild (the result-02 plan, executed).** New out-of-tree cross
   file (`../cross-arm64ec-darwin-teb.txt`, DXMT tree untouched) adds `-ffixed-x18` and
   the darwin-teb-overlay include so the patched `winnt.h` (TSD-slot-6 `NtCurrentTeb`,
   its `#if` branch already covers `__arm64ec__`) shadows the toolchain's. 158/158
   targets, zero source changes. The x18 fault storm died as predicted.
2. **Prebuilt-CRT residue: `_CRT_INIT` still read x18.** Word-boundary objdump census
   (`grep -cE '\bx18\b'`; plain `x18` matches hex constants and lies) showed 7/5/3
   surviving register uses — all in llvm-mingw's prebuilt objects, which no rebuild flag
   touches: `_CRT_INIT`/`DllMainCRTStartup` read `[x18,#0x8]` (NtTib.StackBase entropy),
   `__cxa_get_globals` reads `[x18,#0x58]` (ThreadLocalStoragePointer). The first fired
   at RVA 0x10ac during winemetal's init → unresolved fault → exception-dispatch spin.
   Fix (fork `5a0f6d4`): extend the exact-opcode x18 backstop allowlist {0x60,0x1788} →
   +{0x8,0x58}. Init/throw-only ≈ a handful of 8.9 µs events per process; the FEX probe
   at 0x808 stays deliberately unabsorbed, so the `4d5daa4` failure mode cannot recur.
3. **winemetal.so is not self-contained.** With the storm gone, `DllMain` failed cleanly:
   `__wine_init_unix_call` → host `dlopen` → `Library not loaded: @rpath/winemac.so`.
   DXMT links its unixlib against `@rpath/{ntdll,winemac}.so` (and winemac needs
   `win32u.so`), expecting installation *into* a Wine `aarch64-unix` dir where they are
   siblings. Standalone-tested with a 12-line dlopen probe. Fix: three symlinks beside
   `winemetal.so` in the install dir pointing at the real build-2 dylibs — dyld dedups
   by file identity, so they bind to the already-loaded images.
4. **`macdrv_functions` — the real integration surface.** DXMT resolves a table of
   winemac.drv internals via `dlsym(RTLD_DEFAULT, "macdrv_functions")` (all of them
   hidden-visibility in stock Wine). A dlsym interposer (`DYLD_INSERT_LIBRARIES`, logs
   name→result; no tree changes) proved the lookup, then the win_data ABI trap: DXMT
   dereferences the returned struct with the **pre-consolidation layout** — it reads
   `client_cocoa_view` at offset 0x18 where Wine 11.13 keeps `rects` coordinates (the
   modern struct has a single `client_view` at 0x10). Raw exports would hand DXMT a
   number as a pointer. Fix (fork `ddad4ac`): export the table, but route
   `get_win_data`/`release_win_data` through a shim that returns DXMT's expected layout.
5. **No client view without a GL/VK surface.** Shim tracing showed
   `client_view 0x0` on a valid window: Wine 11.13 materializes the client Cocoa view
   only when a client surface attaches (`window.c` surface machinery), while DXMT's
   target Wine made one eagerly per window. Fix (same commit): the shim carries the
   *hwnd* as the opaque view token (DXMT never dereferences it, only passes it back);
   the table's `macdrv_view_create_metal_view` wrapper materializes the view on demand
   via `macdrv_CreateClientSurface(hwnd, 0)` — frame, superview attach, unhide, and
   `data->client_view` all handled by the standard path — then calls the real
   `macdrv_view_create_metal_view`. Handles stay raw `MTLDevice`/`WineMetalView`/
   `CAMetalLayer` pointers on both sides (verified in `cocoa_window.m`), so DXMT's own
   device passes straight through. The surface object intentionally lives as long as
   the window (a per-window allocation, released by the window-destroy detach path).

## Shear census (standing rule)

323 census events in the first-light run: 320 noaccess-class 0 (benign mixes) plus the
same three noaccess-class sites known since result 06 (JIT temp buffer, CallRetStack,
cache tail — all `view map`, FEX-internal). **The whole D3D11/DXMT path added zero new
interior-NOACCESS pages.** First graphics evidence for the founder-fix priority call:
the shear defect stays confined to FEX's own guard mechanisms.

## Updated install recipe (delta over result 02)

- Build DXMT with `spikes/GFX-001/cross-arm64ec-darwin-teb.txt` (tracked copy; work/
  copy is what the build used). Reconfigure = fresh `meson setup`, not `--wipe`.
- `dxmt-install/aarch64-unix/` needs symlinks `ntdll.so`, `winemac.so`, `win32u.so` →
  the corresponding build-2 dylibs, beside `winemetal.so`.
- Everything else per result 02 (stamped winemetal trigger in system32, native d3d11 +
  dxgi, `WINEDLLPATH`, `WINEDLLOVERRIDES="xtajit64=n;d3d11,dxgi=n"`,
  `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib`).

## Diagnostic patterns worth keeping

- `DYLD_PRINT_LIBRARIES=1` on the wine loader answers "which dylib actually loaded"
  per-pid; `DYLD_INSERT_LIBRARIES` + a `__DATA,__interpose` dlsym shim answers "which
  lookups run and what they return" — both without touching any tree.
- Windows CRT `abort()` = process exit code 3; a "clean" exit 3 with no stage print is
  DXMT's swapchain-ctor abort, not the smoke test's failure path.
- The `addr 0x30` faults in service pids predate this work (present in green baseline
  logs) — background pattern, excluded from graphics triage.

## Frontier (gate 3)

1. Triangle + textured quad guests (shader path: DXBC → airconv → AIR under the same
   stack); then the doc-16 measured scenes.
2. On-screen presentation correctness: readback is exact, but visual placement of the
   materialized client view should be verified when a human looks at the window
   (CreateClientSurface geometry is trusted, unobserved).
3. Present() ran once and the window was pumped briefly — swapchain resize, occlusion,
   and pacing are untested.
