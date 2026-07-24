# GFX-001 result 04 — gate 3 closed: triangle + texture green on the first run

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `ddad4ac` (unchanged from result 03) · **DXMT:** e520fea
(darwin-teb arm64ec build) · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Verdict

```text
stage: compiled vs_main (480 bytes DXBC)
stage: compiled ps_solid (476 bytes DXBC)
stage: compiled ps_tex (704 bytes DXBC)
triangle inside:  b=0 g=255 r=0 a=255 (expected 0 255 0 255)
triangle outside: b=191 g=128 r=64 a=255 (expected 191 128 64 255)
texel (0,0): b=0 g=0 r=255 (expected 0 0 255)
texel (1,0): b=0 g=255 r=0 (expected 0 255 0)
texel (0,1): b=255 g=0 r=0 (expected 255 0 0)
texel (1,1): b=255 g=255 r=255 (expected 255 255 255)
gfx-001 d3d11 draw ok        (exit 0)
```

`testcases/d3d11_draw.c`, first run, **zero new fixes required** — no fork change, no
DXMT change, no install change since result 03. Every readback byte exact.

## What this proves beyond first light

- **The shader pipeline end to end.** Three shaders compiled *at runtime by Wine's own
  `d3dcompiler_47`* (ARM64X builtin — HLSL→DXBC runs native, never under the emulator),
  then DXMT's DXBC→AIR translation (airconv, embedded LLVM 15 in winemetal.so) consumed
  Wine-flavored DXBC first try: vertex passthrough, solid pixel shader, and a pixel
  shader using `SV_Position` input, `int2` truncation, bitwise `&`, and
  `Texture2D.Load`.
- **Rasterization semantics**: input layout, vertex buffers, viewport, triangle list +
  strip topologies, in/out coverage on a clip-space triangle.
- **Texture upload + integer addressing**: an IMMUTABLE 2×2 B8G8R8A8 texture with
  distinct texel colors, verified per pixel parity — the pixel shader samples texel
  `(x&1, y&1)`, so the four checked pixels prove both upload layout (SysMemPitch) and
  addressing with no sampler in the loop.
- **d3dcompiler under the stack is viable as the spike's shader source** — no offline
  FXC needed for gate-4 scene work that compiles from HLSL.

## Shear census (standing rule)

324 events; the three known FEX guard sites plus **one additional instance of the same
chunk-tail signature** (`[23 20 00 00]`, view map, same 0x7ffe… MEM_TOP_DOWN
neighborhood) — consistent with a larger translated-code footprint, not a new class.
Graphics path still contributes zero interior-NOACCESS.

## Frontier (gate 4 — measured scenes per doc 16)

1. Representative scene guests: multi-draw frames with constant buffers, depth, blend
   state — the doc-16 scene list — with frame-time capture.
2. Depth-stencil path is untested (no DSV yet anywhere in the corpus).
3. Constant buffers untested; first scene guest should exercise both.
4. Visual on-screen placement of the materialized client view remains eyeball-unverified
   (readback is the harness standard; check during any manual run).
