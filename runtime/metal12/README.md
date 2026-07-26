<!-- Author: Timur Isaev -->

# Alloy Metal12 runtime

`libAlloyMetal12.a` is the first runnable Metal12 increment under `runtime/`:
one Objective-C static library, one public D3D12-shaped command header, linked
proof clients, a self-contained trace format, and a generic replayer. The
archive owns the canonical promoted M12-001, M12-002, and M12-004 proof
implementations, but the first command path exercises narrower descriptor,
barrier, and residency configurations. Both the linked proofs and the public
command path call the same private model components under `Sources/Models/`.

## Guarantees in this increment

- The canonical library-owned descriptor, barrier, and residency proof
  implementations retain their original fixed seeds and pass/fail thresholds.
  The runtime-local shader tool and corpus preserve their original regression
  subset and named rejection. Descriptor, barrier, shader, and explicitly
  authorized residency-pressure execution are green on the measured host.
- The descriptor heap materializes a GPU-address page, retains it through
  command-buffer completion, and makes that page—not a direct CBV binding—the
  generated fragment shader's resource authority. This path requires macOS 13
  or newer and Metal argument-buffer Tier 2.
- The barrier tracker owns resource state, records actual encoder accesses in
  atomic batches, compiles the dependency plan before encoding, and maps each
  required edge to a producer-specific `MTLFence`. End-of-frame verification
  checks the exact producer/consumer edge mapping.
- Build-time DXIL-to-MSL lowering is exposed as
  `AM12LowerDXILToMSL`. The request cannot select an interpreter or script:
  the library pins `/usr/bin/python3` and embeds the canonical lowerer payload
  plus its build-time SHA-256; it rejects inconsistent embedded DXIL and
  DXC-disassembly hash values and validates the emitted MSL, provenance, and
  fixtures before publication. Container parts, resources, operations, child
  descriptors, and wall-clock execution are bounded. Same-shader publication
  is serialized; ordinary failures trigger rollback, and interrupted
  transactions are recovered before the next publication.
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
Sources/Models/               shared descriptor, barrier, and residency models
Sources/                      runtime, lowering boundary, and linked proofs
ShaderTools/                  canonical DXIL-to-MSL build-time tool
Specs/TRACE_FORMAT_V1.md      persisted capture contract
Tests/                        linked proof and reference clients
Tests/compare_reference.py    canonical fail-closed image comparator
Tools/                        linked lowering and scene-free replay clients
build.sh                      static library and executable build
run-model-proofs.sh           original model thresholds
run-shader-corpus.sh          DXIL/MSL GPU-exact corpus
run-reference-trace.sh        live, capture, replay, and presentation proof
```

Python remains a production-local build-time implementation detail rather than
a frame-time dependency. Callers enter it only through the linked public
contract; the static runtime consumes the resulting metallib.

## Model ownership and convergence boundary

The full native proofs live under `Sources/Proofs/`, compile into
`libAlloyMetal12.a`, and are invoked by tiny separately linked clients:

| Model | Shared implementation | Linked proof | Public command-path configuration |
| --- | --- | --- | --- |
| Descriptors | `AM12DescriptorHeap` owns records, generations, forward copies, page materialization/cache, poisoning, and completion retirement | 65,536 slots, 64 pages, two queues, 1,342,296 verified probes | 256 slots and 64 pages; one graphics CBV range at page index 0; 120 page binds govern the rendered pixels |
| Barriers | `AM12BarrierTracker` owns states, access streams, hazard plans, transitive elision, and verification | 10,000 × 200 randomized streams, 6,180,618 hazards, dropped-edge sensitivity, fence/event execution | One queue and one subresource per logical resource; plan edges emit producer-specific Metal fences; 32 accesses per frame |
| Residency | `AM12ResidencyManager` owns budget snapshots, placement/alias leases, checksummed LRU rematerialization, and pressure policy | Alias, LRU, 20,000-operation churn, and advisory-budget pressure paths | Committed shared buffers and a 64 MiB placement heap; one 976 KiB render target in the reference path |

The architectural convergence and measured Gate 1 execution are complete:
proofs and public operations call those shared components, and the explicitly
authorized acceptance run passed the linked full residency path. Routine runs
still keep that hardware-pressure gate opt-in because it reaches roughly
820 MiB during churn and crosses the Metal advisory budget on its full path.

## Build and verify

Run the evidence producers directly so their protected Bash startup policy is
active:

```sh
runtime/metal12/build.sh
runtime/metal12/run-model-proofs.sh
runtime/metal12/run-shader-corpus.sh
runtime/metal12/run-reference-trace.sh --present
```

Without an argument, the model runner executes the descriptor and barrier
proofs, reports the residency proof as not run, and returns status 3 so a
partial run cannot be mistaken for a green Gate 1. After explicit host-risk
approval, `--include-residency-safe` runs placement, LRU, and churn while still
leaving pressure open; `--include-residency-pressure` runs the complete proof,
which allocates through Metal's advisory budget and up to one GiB beyond it.
These are deliberate hardware gates, not routine CI tests.

Shader compilation needs the shared Alloy Wine/FEX runtime. An isolated
worktree must point `ALLOY_WINE`, `ALLOY_FEX_PREFIX`, and `ALLOY_DXC` at a
checkout containing those ignored artifacts. Evidence runs compile every DXC
input freshly into a unique staging directory, a private validated copy of the
three-file DXC bundle, and a unique run-local copy of the recorded Wine prefix;
they do not attach to a server for the shared prefix. DXC receives a fixed,
empty-inherited execution environment. The declared selected Wine/FEX files
are hashed immediately before and after each invocation. This detects changes
to the recorded files around execution; it is not a claim that the complete
mutable Wine prefix or every dynamically loadable runtime file has been
inventoried. A prior compile key or DXIL file is never accepted as proof of a
new compiler execution.

One script invocation is one compiler-evidence batch. Each corpus case and
each reference stage is compiled exactly once, with DXIL and disassembly
emitted together into private run work and reused for every lowering,
GPU-reference, live, capture, replay, and presentation iteration in that
batch. A later invocation intentionally creates independent fresh evidence;
it is not another iteration inside the prior batch.

## Private evidence capture

[`capture-evidence.sh`](capture-evidence.sh) stages the signed source and build
record required by ADR-0012. It reads only explicit first-party source roots and
the fixed `runtime/metal12/build/` output tree for packaged bytes. It also
rehashes the caller-configured DXC bundle and the explicitly declared
Wine/FEX selected-file identity recorded by the run manifests, including the
initial prefix registries, selected Wine PE libraries, bridge, server, and
execution policy. It neither claims a complete load closure nor discovers
dependency source checkouts, and it does not package those proprietary
runtime files or module caches. `build.sh` emits a manifest that binds the
native library and clients to source bytes materialized directly from the
exact Git commit and `runtime/metal12` tree.

Build, proof, and capture publication share a fail-closed lock. The runners
invalidate their prior manifest first, freeze the build products and external
compiler runtime before execution, generate fresh artifacts in unique staging
directories under fixed native-tool and isolated Python environments, recheck
every declared frozen input, and publish the complete run manifest last.
Static-library metadata is normalized so independent runner builds in the same
canonical checkout and selected tool environment converge on one artifact and
manifest identity. The build and shader runners materialize tracked source from
Git objects; the reference runner likewise materializes its HLSL, comparator,
and GPTK answer key from the frozen Git commit. It enforces the recorded image
contract rather than treating comparison metrics as informational. Capture
rejects stale, modified, incomplete, cached, or cross-run evidence.

The source archive is staged privately and hashed before extraction. Its
single fixed root, complete inventory, regular-file bytes, and Git-materialized
file modes must round-trip exactly before the archive is published.

A complete capture refuses dirty state, unsigned task commits, an unsigned tag,
a missing explicit AI-session export, or a missing caller-selected signer. The
same selected fingerprint must verify every task commit, the annotated tag, and
the snapshot manifest. The task boundary is pinned to issue #84's accepted base
commit rather than a movable branch name:

```sh
runtime/metal12/capture-evidence.sh \
  --output /absolute/private/path/m12-84-evidence \
  --session-export /absolute/private/path/codex-session.jsonl \
  --signed-tag m12-84-evidence \
  --openpgp-key FULL_FINGERPRINT
```

`--ssh-key` supports an explicitly selected SSH signer instead. For workflow
testing, `--allow-unsigned-staging` creates a clearly marked incomplete
snapshot and returns status 3. No mode treats local capture as durable
preservation: the signed `SHA256SUMS` file must still receive an external
timestamp and the private snapshot must be uploaded to the approved durable
store. The run manifests are deterministic unsigned execution records; the
snapshot signature authenticates their packaged bytes, not an independent
attestation that the commands executed. Likewise, the required session export
is caller-supplied procedural evidence: capture freezes its bytes and checks
task markers, but no provider signature or independently auditable export
schema is available. A checksummed authenticated-state record and bundled
verifier bind the intended status, reject symlinks and unexpected files, and
verify the selected snapshot signer.

The bundled verifier is not a trust bootstrap: do not execute a verifier taken
from an unauthenticated snapshot. First authenticate `SHA256SUMS` and its
signature with trusted external tooling and an approved fingerprint, or use a
separately trusted copy of the verifier. After that external step, run
`VERIFY-SNAPSHOT.sh OUT_OF_BAND_EXPECTED_SIGNER_FINGERPRINT`. An unsigned
staging snapshot accepts no fingerprint and can check only structure and
checksums, not authenticity.

## Deliberate boundaries

This increment is a trace-driven native Metal runtime, not `d3d12.dll`.
It does not yet claim:

- Windows COM/DXGI entry points or real-title command capture;
- general DXIL ingestion, control flow, or the full shader model;
- implicit or fractional LOD, derivative, gather, comparison-sampler, mip
  chains beyond the tested two levels, or broad texture forms;
- full typed/structured UAV, atomic, wave, depth, or multi-queue semantics;
- texture/sampler descriptor-page virtualization in the shader corpus;
- more than one graphics CBV range, or a range mapped anywhere other than
  descriptor-page index zero;
- a general DXIL parser independent of the hash-matched DXC disassembly
  companion accepted by the current public lowering request; the disassembly
  remains a trusted build input, and its copied hash value is a consistency
  check against accidental mismatches rather than adversarial authentication
  of its body;
- trace portability across arbitrary GPU, OS, or Metal compiler epochs;
- certification outside the measured M2 Pro 16 GB host.

The result documents under `spikes/M12-006/results/` state the exact measured
claim for each gate.
