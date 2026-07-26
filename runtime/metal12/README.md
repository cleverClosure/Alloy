<!-- Author: Timur Isaev -->

# Alloy Metal12 runtime

`libAlloyMetal12.a` is the first runnable Metal12 increment under `runtime/`:
one Objective-C static library, one public D3D12-shaped command header, linked
proof clients, a self-contained trace format, and a generic replayer. The
archive owns the canonical promoted M12-001, M12-002, and M12-004 proof
implementations, but the first command path exercises narrower descriptor,
barrier, and residency subsets. Archive ownership and linkage are not a claim
that those full proof models are already the command layer's implementation.

## Guarantees in this increment

- The canonical library-owned descriptor, barrier, and residency proof
  implementations retain their original fixed seeds and pass/fail thresholds.
  The runtime-local shader tool and corpus preserve their original regression
  subset and named rejection. Descriptor, barrier, and shader execution is
  green; the residency oversubscription execution is recorded as a host-safety
  blocker pending explicit approval.
- The vertical slice uses only
  [`AlloyMetal12.h`](include/AlloyMetal12.h) for resource, descriptor,
  transition, rendering, copy, submission, presentation, and digest work.
- Capture records each public command and every caller-provided resource write.
  The compiled metallib is embedded, so replay has no scene or shader-source
  dependency.
- Trace replay creates a fresh runtime for each run and rejects malformed,
  unknown-major, truncated, or unknown-opcode input.
- Presentation uses a real, visible `CAMetalLayer`. On the final frame, the
  readback is deliberately deferred until after the source-to-drawable blit,
  so the final drawable—not the offscreen source—is the presented run's image
  authority.
- All implementation and evidence follow the provenance boundary in
  [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md).

## Layout

```text
include/AlloyMetal12.h        one public native API
Sources/                      runtime and promoted proof implementations
ShaderTools/                  canonical DXIL-to-MSL build-time tool
Specs/TRACE_FORMAT_V1.md      persisted capture contract
Tests/                        linked proof and reference clients
Tools/metal12_replay.m        scene-free replay executable
build.sh                      static library and executable build
run-model-proofs.sh           original model thresholds
run-shader-corpus.sh          DXIL/MSL GPU-exact corpus
run-reference-trace.sh        live, capture, replay, and presentation proof
```

The Python lowerer is currently a production-local build tool rather than a
runtime Python dependency. The static library consumes its compiled metallib
artifact. This design does not satisfy issue #84 Gate 1's literal requirement
that DXIL-to-MSL sit behind the public header, so the result records that
criterion as open.

## Model ownership and convergence boundary

The full native proofs live under `Sources/Proofs/`, compile into
`libAlloyMetal12.a`, and are invoked by tiny separately linked clients. They
are canonical library-owned test implementations. The trace-driven command
path currently has smaller, scene-bounded implementations:

| Model | Canonical linked proof | First command-path subset | Required shared implementation |
| --- | --- | --- | --- |
| Descriptors | 65,536-slot virtual heap, descriptor copies, generation-sum table cache, 64-page argument-buffer ring, poisoning, and two-queue completion retirement | One constant-buffer view, generation validation, and 120 materializations; the shader receives the buffer directly | Extract `Sources/Models/AM12DescriptorHeap.{h,m}` with slot writes/copies, generation validation, page materialization/cache, and completion retirement; route both the proof and `AM12CreateConstantBufferView`/root-table binding through it |
| Barriers | Randomized per-subresource/alias access planner, transitive-edge elision, 6,180,618-hazard verifier, and Metal fence/event execution | Declared resource states plus the reference scene's single render-to-copy ordering edge, checked against encoder order | Extract `Sources/Models/AM12BarrierTracker.{h,m}` with access recording, alias/subresource hazard planning, and an emitter contract; route both the proof stream and `AM12TransitionResource`/submission through it |
| Residency | Placement alias observation, checksummed LRU rematerialization, 20,000-operation churn, advisory-budget pressure, bailout, and evict/retry | Budget reporting and one 976 KB private-heap render-target placement | Extract `Sources/Models/AM12ResidencyManager.{h,m}` with budget accounting, placement/alias retirement, eviction/rematerialization, and pressure policy; route both the proof and runtime resource creation through it |

That convergence is complete only when each proof and the public command path
call the same private model implementation and the original thresholds pass
again. Merely moving proof code into another object file would preserve
linkage while leaving the architectural gap unchanged.

## Build and verify

Put the pinned toolchain on `PATH`, then:

```sh
export PATH="$PWD/tools/toolchains/"llvm-mingw-*/bin:$PATH
runtime/metal12/build.sh
runtime/metal12/run-model-proofs.sh
runtime/metal12/run-shader-corpus.sh
runtime/metal12/run-reference-trace.sh --present
```

Without an argument, the model runner executes the descriptor and barrier
proofs, reports the residency proof as not run, and returns status 3 so a
partial run cannot be mistaken for a green Gate 1. After explicit host-risk
approval, pass `--include-residency-pressure`; that proof deliberately
allocates through Metal's advisory budget and up to one GiB beyond it. It is a
hardware gate, not a routine CI test.

Shader compilation needs the shared Alloy Wine/FEX runtime. An isolated
worktree must point `ALLOY_WINE`, `ALLOY_FEX_PREFIX`, and `ALLOY_DXC` at a
checkout containing those ignored artifacts. The scripts compile each shader
once into `runtime/metal12/build/` and reuse the cached DXIL.

## Deliberate boundaries

This increment is a trace-driven native Metal runtime, not `d3d12.dll`.
It does not yet claim:

- Windows COM/DXGI entry points or real-title command capture;
- general DXIL ingestion, control flow, or the full shader model;
- implicit or fractional LOD, derivative, gather, comparison-sampler, mip
  chains beyond the tested two levels, or broad texture forms;
- full typed/structured UAV, atomic, wave, depth, or multi-queue semantics;
- texture/sampler descriptor-page virtualization in the shader corpus;
- shared full-proof descriptor, barrier, and residency model implementations
  on the public command path;
- a DXIL-to-MSL operation behind the public native header;
- trace portability across arbitrary GPU, OS, or Metal compiler epochs;
- certification outside the measured M2 Pro 16 GB host.

The result documents under `spikes/M12-006/results/` state the exact measured
claim for each gate.
