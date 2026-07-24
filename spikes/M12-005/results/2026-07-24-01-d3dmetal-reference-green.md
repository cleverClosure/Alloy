# M12-005 result 01 — D3DMetal reference scene is green through CrossOver 26.3

**Author:** Timur Isaev
**Date:** 24 July 2026
**Hardware:** MacBook Pro (Mac14,10), M2 Pro 12-core, 16 GB
**OS:** macOS 26.5.2 (25F84)
**Status:** Green baseline on the installed D3DMetal 3.0 provider; direct GPTK 4 package refresh pending Apple ID sign-in

## Why this exists

The four first Metal12 spikes proved isolated implementation risks, but D4
still lacked a rendered D3D12 answer-key scene from Apple's evaluation path.
This result adds an original, reproducible x64 D3D12 workload, proves that the
installed D3DMetal provider rendered it, and captures both a visual reference
and timing baseline. It does not use or inspect any excluded D3D12
implementation.

## Provider identity and selection proof

Apple's current [Game Porting Toolkit page](https://developer.apple.com/games/game-porting-toolkit/)
identifies Game Porting Toolkit 4 as current and lists CrossOver as a supported
way to use the Windows-game evaluation environment. The installed lab path is:

| Component | Identity |
| --- | --- |
| CrossOver | 26.3 |
| D3DMetal | `PROGRAM:D3DMetal PROJECT:D3DMetal-3.0` |
| D3DMetal SHA-256 | `05a7beaed4494a4f5f53d3f626a82fffc3b70146436a908b7048a0632a49e1a8` |
| Backend proof | `set_graphics_backend using d3dmetal as the graphics backend` |

The `vkd3d:D3DCompile2VKD3D` lines in the run log come from Wine's HLSL
compiler used by `D3DCompile`; they do not select the graphics backend. The
process trace above is the authoritative backend signal.

## Workload

[`d3d12_reference.c`](../scene/d3d12_reference.c) builds as an x64 PE with the
pinned llvm-mingw toolchain. It creates a D3D12 device and flip-model swap
chain, compiles vertex and pixel shaders, updates root constants, draws 120
procedural frames, presents and fences each frame, copies the final
backbuffer to a readback resource, and writes a bitmap.

The final image must differ from its first pixel in at least 75% of pixels.
This prevents a clear-only or blank window from passing as a render.

## Result

Command:

```sh
spikes/M12-005/scene/run-reference.sh
```

| Measurement | Result |
| --- | ---: |
| D3D12 setup | 272.817 ms |
| First submitted frame | 167.600 ms |
| Warm mean (119 frames) | 8.262 ms |
| Warm p50 | 8.263 ms |
| Warm p95 | 11.151 ms |
| Nonuniform pixels | 230,397 / 230,400 |
| Pixel FNV-1a 64 | `825861ee12085256` |
| PNG SHA-256 | `6300cd9f0717bb89d8d4a3fffc9a290edbe0834a2f4c64a29ad1888e9fd62974` |
| Exit | `status: PASS` |

![D3DMetal D3D12 reference scene](2026-07-24-d3dmetal-reference.png)

Repeated runs produced the same pixel digest and PNG hash. Timing is a
single-machine engineering baseline, not a product performance claim.

## Legal and repository boundary

- D3DMetal remains internal, non-commercial evaluation material.
- No GPTK, D3DMetal, or CrossOver binary is copied into Alloy.
- The committed image is output from Alloy's first-party workload.
- Generated bottles, PEs, raw logs, and bitmaps remain under ignored `work/`.
- The runner uses a dedicated bottle and does not modify the user's Steam
  bottle.

## Remaining refresh

The official GPTK 4 evaluation-environment download currently stops at Apple
ID sign-in. Once the founder completes that account-bound step, rerun this
same scene against the package's D3DMetal version and append a second result;
the current D3DMetal 3.0 baseline remains useful for version-to-version
comparison.
