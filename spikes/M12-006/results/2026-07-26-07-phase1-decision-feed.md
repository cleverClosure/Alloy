# M12-006 result 07 — Phase-1 evidence narrows the Metal12 GA subset

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Decision feed complete; all six Phase-1 gates are green on
the measured host

## Exact evidence set

- Result 02: shared runtime/model promotion, M12-001 and M12-002 reruns,
  public fail-closed lowering, integrated reference client, and the authorized
  M12-004 pressure pass.
- Result 03: deterministic, pixel-neutral command capture.
- Result 04: ten-run scene-free replay plus fail-closed validation.
- Result 05: wider texture and wave shader subset.
- Result 06: the recorded three-run `CAMetalLayer` series plus one
  manifest-bound 120-frame final-acceptance reproduction.
- Final-acceptance reproduction at tested execution commit
  `94afcc2fee0742b0887f46cd356e1c54a4bb191d` and runtime tree
  `77d5f21cfbdacf8472156f9586942eb6c020a251`. Its unsigned staging payload
  is checksum-closed but explicitly unauthenticated, and it does not cover
  this later documentation-only descendant.
- Authorized residency-pressure execution at tested commit
  `5c463b76dd18f37c06a4ab22b11d5347514fab21`, runtime tree
  `c0b354313cc9d97f69c0b19d6a138e9ce7b44f39`, model-manifest SHA-256
  `c9aebbf498fa22ec5e44b4eeb8f2fc00dbe4d90957e4eb481ffba61b84afe8d0`,
  and unsigned staging `SHA256SUMS` digest
  `2b8ef5a50a20dc3a52c8833b206d1a01cb2bfaae9b0fa262bbfde9a6752a0d6d`.
- M12-001 through M12-006 provenance logs and
  `runtime/metal12/PROVENANCE.md`.

## Feature subset now measured

| Area | Measured now | Remaining boundary |
| --- | --- | --- |
| Descriptor heap | One shared `AM12DescriptorHeap`: linked 65,536-slot proof with 1,342,296 probes and zero mismatch; vertical 256-slot configuration with a completion-retained GPU-address page governing 120 rendered binds | More than one graphics CBV range; texture/sampler descriptor pages; broader root signatures |
| Barriers | One shared `AM12BarrierTracker`: 6,180,618 proof hazards, zero uncovered, 90% edge elimination; runtime tracker-only state and exact plan-derived fences, with 1/1 offscreen and 121/121 presented edges emitted | Depth classes, broader render classes, copy-queue triples, three-plus queues, more than 32 modeled accesses per frame |
| Shaders | Public `AM12LowerDXILToMSL` with an embedded pinned lowerer, bounded container/resources/operations/child execution, DXIL/DXC embedded-hash consistency checking, validated artifacts, ten GPU-exact compute cases, 15-op vertex and 99-op fragment lowering, and one named rejection | Authentication or derivation of caller-provided disassembly from DXIL bitcode; general control flow/DXIL ingestion, implicit LOD, derivatives, gather/compare, broader resources, atomics, waves, and stages |
| Residency | One shared `AM12ResidencyManager` owns committed buffers, placement leases, alias/LRU/churn/pressure policy; 109 eviction-cache rematerializations verified with zero mismatches; 20,000 churn operations peaked at 820 MB; pressure reached 13,184 MB against a 12,124 MB budget with zero allocation failure; post-release Metal allocation returned to its 0.1 MB baseline and process footprint measured 3.8 MB | 24/32/64 GB matrix remains unmeasured |
| Capture/replay | Versioned self-contained TLV, byte-identical duplicate captures, 6/6 command rejections, 17/17 trace mutations, and ten fresh runtimes with digest `44709706809f28e9` | Real engine/title captures and portability across GPU/OS/compiler epochs |
| Presentation | Three recorded visible 640 × 360 `CAMetalLayer` runs plus one final-acceptance reproduction, 120 frames each, byte-identical output, and exact 121/121 fence edges | Resize, occlusion, HDR/high-DPI, multi-window, and long-session pacing |

## Pending decision 3

The new evidence supports a **measured first GA-candidate slice**, not a GA
feature-set decision:

- one native runtime library executes a recorded straight-line render workload
  instead of a hand-fed prototype;
- the full proofs and public command path now call the same descriptor,
  barrier, and residency components;
- the public lowering boundary prevents caller-selected executables, rejects a
  pair whose embedded hash values disagree, and validates artifacts before
  publication;
- the materialized descriptor page governs the fragment shader's CBV load;
- the barrier plan drives producer-specific Metal fence waits and is checked
  edge by edge;
- the workload captures once, replays without scene code, and presents without
  changing its image;
- explicit-LOD 2D sampling and a small wave subset have independent GPU
  exactness evidence.

Decision 3 should retain the straight-line, explicit-LOD,
single-render-target/single-CBV slice as an implementation milestone while
refusing to name it a title-capable GA subset. Control flow, resource and
descriptor breadth, real trace diversity, depth/render breadth, and Windows
entry-point integration remain feature gates, not cleanup.

The explicitly authorized M12-004 execution passed through the shared library:
the eviction cache verified 109 rematerializations with zero mismatches,
20,000 churn operations peaked at 820 MB, and the proof allocated 13,184 MB
against Metal's 12,124 MB advisory budget with zero allocation failure.
Post-release Metal allocation returned to its 0.1 MB baseline, and process
footprint measured 3.8 MB.

## Unmeasured work carried forward

- Broader DXIL ingestion and structured control flow.
- Implicit LOD, derivatives, gathers, comparison sampling, mip and texture
  breadth.
- Typed/structured UAV and atomic breadth.
- Full wave semantics and non-compute shader-stage breadth.
- Multiple graphics CBV ranges plus texture and sampler descriptor pages.
- Three-plus queues, depth, and broader render/copy barriers.
- 24/32/64 GB residency matrix.
- Trace portability across Apple GPU, OS, and Metal compiler epochs.
- Full DXGI/D3D12 entry points and real-title coverage.

## Provenance and claim boundary

The dated tool/input record is appended to both required provenance logs. No
excluded D3D12 translation source, diff, history, or quoted implementation
entered the work.

This document feeds pending decision 3 with the new numbers. It does not make
the decision on the founder's behalf, treat a narrow reference trace as a
title-capable runtime, or extrapolate one host's pressure pass into the
unmeasured memory-capacity matrix.
Later acceptance runs are separate manifest-bound evidence generations; they
do not silently replace the named historical timing series in results 02–06.
