# GFX-001 result 05 — measured scene green, cold-boot crash root-caused and fixed, launcher split green

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `87adaaa` · **DXMT:** e520fea (darwin-teb arm64ec build)
**Hardware:** M2 Pro, 16 GB, macOS 26.5

## What gate 4 now has (and what it still needs)

Doc 16's full gate-4 scope is real candidate titles — blocked on STORE-001 entitled
installs (founder credentials). This result closes the **feasibility layer under it**:
a scene-shaped synthetic workload with the doc-16 metrics — sustained frame pacing,
cold/warm behavior, memory boundedness — plus the previously-untested API surface and
the launcher/game process split. Everything measurable without a title is measured.

## The workload

`testcases/d3d11_scene.c`: 1280×720, 660 frames (60 warmup + 600 measured), **202 draws
and 202 dynamic-cbuffer `Map(WRITE_DISCARD)` updates per frame** (the per-draw hot path
engines hammer): 100 opaque depth-tested quads, 100 alpha-blended depth-read-only quads,
2 flat anchor quads. Exercises for the first time in this stack: constant buffers,
`D32_FLOAT` depth-stencil, blend states, linear samplers, per-frame `Present` in a loop.
Self-verifying: the anchor corner draws red at z=0.3 *then* blue at z=0.7 — the pixel
must stay red, proving depth rejection worked every run. A per-frame commit-step
detector localizes any >64 MB single-frame pagefile jump to its exact frame.

## Numbers (5 clean post-fix runs; cold = fresh wineserver boot)

```text
frame time ms: mean 3.0-4.3  p50 1.9-2.1  p95 10.5-16.3  p99 16.5-20.7  max 22.7-24.4
throughput:    233-329 fps mean
first frame (device -> present, cold pipelines): 23.7-38.3 ms
memory: working set ~158 -> ~180 MB every run; pagefile delta +3.5 to +5.1 MB
        over 600 frames; depth anchor exact in every run
```

- p50 ~2 ms at 202 draws/frame means the EC-boundary cost per draw (guest x64 → FEX →
  native DXMT) is roughly 10 µs at this workload — comfortable headroom against a 16.7 ms
  frame budget for the MVP catalog's D3D11 titles.
- The long tail (p95/p99 ~10–20 ms) is periodic, not random: consistent with compositor/
  display interaction under `Present(0,0)` on a visible window. Real-title pacing work
  (proper swap intervals, occlusion) is the Phase-1 item; the spike question — "is there
  a structural pacing collapse?" — answers no.
- An earlier pair of runs measured ~120 fps mean; those ran alongside a crashed sibling
  process parked under winedbg and are superseded by the clean-environment runs above
  (identical benign-fault counts rule out fault-storm differences).

## Cold-boot crash: root-caused in our own fork code, fixed (`87adaaa`)

First-ever scene runs after a fresh wineserver boot crashed **2 for 2** with an
unhandled NULL+0x30 read on the guest main thread at a deterministic address —
symbolized (per-run `+loaddll` bases + `llvm-symbolizer`) to
**`fex_dispatch_ret_wrapper`, `signal_arm64ec.c` — the fork's own TSD sequence** from
the x18 TEB-contract commit:

```asm
mrs x18, tpidrro_el0        ; TSD base
ldr x18, [x18, #0x30]       ; TSD slot 6 -> TEB   <- faulted with x18 == 0
```

The same sequence's unix-side twin is what produces the long-standing *absorbed*
`addr 0x30` faults in service processes — one mechanism, two visibilities. The fix
leans on a happy structural coincidence: x64 TEB offset 0x30 is `NtTib.Self`, which
holds the TEB pointer itself — so the existing exact-opcode backstop, taught offset
0x30, emulates the load from the real TEB and restores precisely the wrapper's intent,
regardless of whether tpidrro read zero or control re-entered the wrapper past the
`mrs` with a kernel-zeroed x18. FEX's designed-to-fail probe at 0x808 stays unabsorbed.
**Verified: cold-boot crashes 2/2 → 0/5; corpus green (`x64hello 0, isa_smoke 0,
jit_pages 7` known, `win_smoke 0`).**

## Launcher/game process split (doc-16 scope item): green

`testcases/launcher_split.c` — a guest launcher `CreateProcess`es `d3d11_smoke.exe` and
propagates its exit code. Exit 0: the D3D11 provider comes up fully (device, swapchain,
exact readback) in a launcher-spawned child. Combined with WINE-001's pre-import policy
routing, the launcher/game split story is prototype-complete.

## Open item: the ~1.31 GB one-time commit step

Twice in eight scene runs, `PagefileUsage` stepped +1.31 GB inside the measured window —
both times on the first run after an ntdll.so rebuild; never twice, never cumulative,
working set unaffected (~180 MB always). The per-frame detector now rides in the guest,
so any recurrence prints its exact frame. Best current hypothesis: a first-use lazy
arena (FEX translation cache or Metal compiler service) whose timing usually lands in
warmup. Not a leak-shaped risk; attribution deferred until it recurs with the detector.

## Shear census (standing rule)

Known FEX guard signatures only, across all scene runs; the graphics path has
contributed zero interior-NOACCESS through gates 2–4.

## Remaining for full doc-16 gate 4 (all title-gated)

Real candidate games (STORE-001 entitled installs), cold/warm scene automation on
titles, shader-stall capture on real content, visual reference capture, long-session
memory on titles. The synthetic layer is done.
