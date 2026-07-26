# M12-006 result 07 — Phase-1 evidence narrows the Metal12 GA subset

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Decision feed complete; Gate 1 remains partial at the
full-model integration and public-lowering boundaries, and retains one
host-approval blocker

## Exact evidence set

- Result 02: runtime/library promotion, M12-001 and M12-002 reruns, original
  shader regression, integrated reference client, public-lowering boundary,
  and the M12-004 execution blocker.
- Result 03: deterministic, pixel-neutral command capture.
- Result 04: ten-run scene-free replay.
- Result 05: wider texture and wave shader subset.
- Result 06: 120 presented CAMetalLayer frames and comparable timing.
- M12-001 through M12-006 provenance logs and
  `runtime/metal12/PROVENANCE.md`.

## Feature subset now measured

| Area | Measured now | Remaining boundary |
| --- | --- | --- |
| Descriptor heap | Canonical linked proof: buffer records, generations, copies, page ring/cache, and two-queue in-flight lifetime — 1,342,296 probes, zero mismatch. Vertical runtime: one directly bound CBV with generation validation and 120 materializations | The command path does not yet share the proof's page/cache/retirement implementation; texture/sampler descriptor pages are not on the corpus critical path |
| Barriers | Canonical linked proof: per-subresource and alias hazard model, two queues, fence/event execution — 6,180,618 hazards, zero uncovered, 90% edge elimination. Vertical runtime: 122 transitions and one render-to-copy edge checked against encoder order | The command path does not yet share the proof's randomized hazard planner; depth classes, broader render classes, copy-queue triples, three-plus queues |
| Shaders | Compute/vertex/fragment straight-line subset; scalar arithmetic; raw/structured buffer operations; explicit-LOD point and bilinear Texture2D sampling; active sum, lane index, exclusive prefix; named rejection | The corpus invokes the production-local Python lowerer directly rather than through the public header required by Gate 1; general control flow/DXIL ingestion, implicit LOD, derivatives, gather/compare, broader resources/atomics/waves/stages |
| Residency | Canonical linked proof source retains alias, checksum eviction, 20k churn, and advisory-budget logic; vertical runtime reports the budget and places one 976 KB render target | The command path does not yet share the proof's alias/eviction/pressure manager; linked high-pressure rerun awaits explicit host-risk approval; 24/32/64 GB matrix remains unmeasured |
| Capture/replay | Versioned self-contained TLV, byte-identical duplicate captures, ten fresh runtimes with digest `44709706809f28e9` | Real engine/title captures and portability across GPU/OS/compiler epochs |
| Presentation | Visible 640 × 360 CAMetalLayer, 120 frames, pixel-identical output, warm mean/p50/p95 measured against GPTK | Resize, occlusion, HDR/high-DPI, multi-window and long-session pacing |

## Pending decision 3

The new evidence supports a **measured first GA-candidate slice**, not a GA
feature-set decision:

- one native runtime library can execute a recorded straight-line render
  workload instead of a hand-fed prototype;
- the same archive owns the full descriptor, barrier, and residency proof
  implementations, but the recorded workload currently exercises only the
  smaller command-path subsets stated above;
- the canonical DXIL-to-MSL lowerer is promoted under `runtime/metal12`, but
  remains a directly invoked Python build tool rather than a public-header
  library operation;
- the workload can be captured once, replayed without scene code, and presented
  without changing its image;
- explicit-LOD 2D sampling and a small wave subset now have independent GPU
  exactness evidence;
- the honest presented comparison is no longer an offscreen speedup claim:
  Metal12 warm mean is 12.919 ms versus GPTK's 6.165 ms on this workload.

Decision 3 should therefore retain the straight-line, explicit-LOD,
single-render-target slice as an implementation milestone while refusing to
name it a title-capable GA subset. Control flow, general resource/descriptor
coverage, real trace diversity, depth/render breadth, and Windows entry-point
integration remain feature gates, not cleanup.

The M12-004 high-pressure execution must also be rerun through the promoted
library after explicit approval before task #84 can claim every Gate 1
threshold anew.

Before the runtime can claim that the full Gate-1 models are its production
implementation, it must extract private `AM12DescriptorHeap`,
`AM12BarrierTracker`, and `AM12ResidencyManager` components under
`runtime/metal12/Sources/Models/`; both each proof and the matching public
command operations must call those components; and the original proof
thresholds plus the reference trace must pass together.

Gate 1 also remains open until DXIL-to-MSL lowering is exposed through the
single public library header, as the issue requires. Promoting the Python tool
and consuming its metallib output does not satisfy that literal boundary.

## Unmeasured work carried forward

- Public-header DXIL-to-MSL ingestion and structured control flow.
- Implicit LOD, derivatives, gathers, comparison sampling, mip and texture
  breadth.
- Typed/structured UAV and atomic breadth.
- Full wave semantics and non-compute shader-stage breadth.
- Texture and sampler descriptor-page virtualization.
- Three-plus queues, depth, and broader render/copy barriers.
- 24/32/64 GB residency matrix and the blocked linked pressure rerun.
- Trace portability across Apple GPU, OS, and Metal compiler epochs.
- Full DXGI/D3D12 entry points and real-title coverage.

## Provenance and claim boundary

The dated tool/input record is appended to both required provenance logs. No
excluded D3D12 translation source, diff, history, or quoted implementation
entered the work.

This document feeds pending decision 3 with the new numbers. It does not make
the decision on the founder's behalf and does not erase the explicit Gate 1
model-convergence, public-lowering, or hardware-pressure blockers.
