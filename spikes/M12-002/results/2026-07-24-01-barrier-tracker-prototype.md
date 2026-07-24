# M12-002 result 01 — barrier/state tracker: 90% sync elimination at zero uncovered hazards

**Author:** Tim Isaev
**Date:** 24 July 2026
**Hardware:** M2 Pro, 16 GB, macOS 26.5 · **Provenance:** ADR-0012 discipline model,
inputs logged in [PROVENANCE.md](../PROVENANCE.md) — no excluded source consulted.

## Verdict

```text
model: 10000 streams x 200 ops, 6180618 hazard pairs, 0 uncovered
plans: conservative 1934 edges/stream, optimized 193.3 (90.0% eliminated)
sensitivity: dropped-edge detection 100/100
gpu fence chain: 0 errors after 32 rounds
gpu cross-queue chain: 0 errors after 32 rounds
gpu intervals: A 24.7 ms, B 24.8 ms, hardware overlap 24.7 ms
m12-002 barrier tracker ok
```

The doc-16 hypothesis holds at prototype scope: a conservative D3D12-style state
tracker optimizes into a Metal sync plan that drops **90% of ordering edges** while
covering **every one of 6.18 million hazard pairs** across 10,000 randomized
two-queue streams — and the checker's authority is falsifiable (dropping any single
emitted edge is detected 100/100).

## Design (original; see PROVENANCE.md)

- **Streams**: per-subresource reads/writes, transitions modeled as whole-resource
  write-class accesses, an aliased memory pair tracked at memory-object granularity,
  two queues. Deliberately pessimal premise: *nothing* is implicitly ordered — not
  even same-queue program order — so the plan alone carries all correctness.
- **Ground truth** is built independently of both compilers: every same-memory,
  overlapping-slot pair with a write is a hazard; a plan passes only if reachability
  through its edges covers every hazard pair in recording order.
- **Optimized compiler**: per-(memory, subresource) last-write + readers-since-write
  tracking emits candidate edges (RAW/WAR/WAW only — read-read never syncs), then a
  true happens-before bitset elides edges already implied transitively, newest source
  first.
- **The instructive bug**: the first elision summarized happens-before as a per-queue
  max position — unsound precisely because unfenced same-queue work is unordered in
  this model, and 1.2 M hazards escaped. Full reachability bitsets fixed it at zero
  measurable cost (0.85 s for the whole 10k-stream suite). The per-queue-clock
  shortcut is only valid in a model where queues are serial — worth remembering when
  the production tracker chooses its memory/precision trade-off.
- **Execution leg**: writer→`MTLFence`→checker within a queue and
  writer→`MTLSharedEvent`→checker across queues, 32 self-checking rounds each, clean.

## Hardware scheduling finding (feeds Metal12 queue mapping)

GPU timestamps prove two compute command buffers from two queues **run concurrently**
on M2 Pro (24.7 ms of interval overlap). But for same-typed ALU-saturating kernels,
each stretched ~3× while sharing the machine: concurrent wall-clock 25.2 ms vs 16.5 ms
fence-serialized — concurrency *lost* by ~50% for this shape. Implication for the
provider: mapping D3D12 compute queues 1:1 onto Metal queues is not automatically a
win; same-typed ALU-bound queues may deserve coalescing onto one Metal queue, with
true async reserved for heterogeneous (render+compute, bandwidth-vs-ALU) pairings.
The tracker's contribution — never *adding* false ordering — is proven independently
of this scheduling choice.

## Doc-16 pass evidence

| Evidence | Result |
| --- | --- |
| Randomized correctness | 6,180,618 hazard pairs, 0 uncovered; conservative control always passes; checker falsifiability 100/100 |
| No corruption | 64 self-checking GPU rounds (fence + cross-queue event), 0 errors |
| Redundant-sync elimination | 90.0% of conservative edges dropped |
| Queue overlap | proven at hardware level via GPU timestamps, with the same-typed-workload penalty quantified |

## Honest limits

- Compute-only; render-target barrier classes and texture layout transitions are not
  modeled (Metal has no layout transitions, but RT/depth fence scoping differs).
- Two queues; copy-queue triples deferred.
- Real engine trace replay deferred to Phase 1 (needs captures).

## Build & run

`clang -fobjc-arc -O2 -o work/barrier_tracker prototype/barrier_tracker.m -framework
Metal -framework Foundation` — self-verifying, exit 0 = green (fixed seed).
