# M12-001 result 01 — virtual descriptor heap on Metal 3 argument buffers: model green

**Author:** Tim Isaev
**Date:** 24 July 2026
**Hardware:** M2 Pro, 16 GB, macOS 26.5 · **Provenance:** ADR-0012 discipline model,
inputs logged in [PROVENANCE.md](../PROVENANCE.md) — no excluded source consulted.

## Verdict

```text
descriptor update: 0.7 ns/descriptor (1M heap writes)
sensitivity: deliberate early recycle -> 64/64 poison reads (detector proven)
randomized model: 1342296 probes verified, 0 mismatches
page encode: 24.5 ns/descriptor (271164 descriptors)
table cache: 485 hits / 1915 misses (20.2% hit on repeat-bind mix)
page pool: 64 pages, high-water in-flight 17, stalls 0
resident memory: 27.0 MB
m12-001 descriptor virtualization ok
```

The doc-16 hypothesis holds at prototype scope: a D3D12-style shader-visible
descriptor heap maps onto Metal 3 argument buffers (plain GPU-address arrays) with
correct in-flight lifetime and CPU costs that leave large headroom.

## Design (original; see PROVENANCE.md)

- **Virtual heap** = CPU-side record array (64K slots): resource ref + generation.
  Descriptor writes and `CopyDescriptors`-style range copies mutate records only —
  0.7 ns each, three orders of magnitude below any per-frame budget.
- **Binding** materializes the referenced range into a fixed 256-entry **page**
  (a `uint64` GPU-address array in a shared MTLBuffer) allocated from a 64-page ring.
  MSL consumes it by pointer-casting entries — the Metal 3 bindless idiom. 24.5 ns per
  descriptor encoded.
- **Lifetime**: pages carry an in-flight refcount driven by command-buffer completion
  handlers across **two queues**; a page returns to the ring only at zero. Returning
  pages are **poisoned** with a sentinel resource, so any use-after-recycle becomes a
  guaranteed, loud divergence rather than a silent stale read.
- **Table cache**: a bound table whose slot-generation sum is unchanged reuses its
  encoded page — the "no forced full-table rebuild on common paths" evidence (20.2%
  hit under a randomized mix that rebinds the same table 1 in 4 times).
- **Verification**: resources are self-identifying; a probe kernel dynamically indexes
  the bound page (with a 4000-step dependent LCG per thread to hold pages on-GPU long
  enough for real overlap) and reports the ids it read; a CPU model predicts every
  probe from heap state at encode time. 16 command buffers deep, both queues.

## Doc-16 metrics

| Metric | Evidence |
| --- | --- |
| Zero model mismatch / use-after-recycle | 1,342,296 probes, 0 mismatches; detector falsifiability proven by a deliberate early recycle (64/64 poison reads) |
| Bounded memory | fixed 64-page ring; high-water 17 pages in flight; 0 stalls; 27 MB resident |
| Descriptor update CPU cost | 0.7 ns record update; 24.5 ns full page-encode path |
| No full-table rebuild on common paths | generation-sum page cache, 20.2% hit on the randomized repeat-bind mix |

## Honest limits

- Buffers only; textures/samplers use `MTLResourceID` in the same page layout — same
  mechanics, not yet exercised.
- The dynamic-index probe covers tier-2-style unbounded indexing; divergent
  non-uniform indexing across SIMD groups is not separately stressed.
- Engine trace replay (doc 16) needs real captured traces — Phase 1.
- Residency here is per-encode `useResource`; production wants MTLHeap/residency sets.

## Build & run

`clang -fobjc-arc -O2 -o descriptor_vheap prototype/descriptor_vheap.m -framework Metal
-framework Foundation` — self-verifying, exit 0 = green (fixed seed, deterministic).
