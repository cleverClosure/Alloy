# SPIKE-M12-001 — Descriptor and binding virtualization

**Author:** Tim Isaev
**Status:** Active (started 24 July 2026)
**Canonical definition:** [doc 16 §M12-001](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md)
**Provenance:** [ADR-0012 discipline model](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md) · log in [PROVENANCE.md](PROVENANCE.md)

**Hypothesis:** D3D12 descriptor heaps/root signatures can map to Metal argument
buffers with correct in-flight lifetime and acceptable CPU overhead.

## Method

Native macOS prototype (no Wine/FEX in the loop — this is provider-internal R&D):
a virtual shader-visible descriptor heap (CPU-side records), root-table binding that
materializes referenced heap ranges into fixed-size argument-buffer **pages** (Metal 3
GPU-address arrays) drawn from a recycling ring, and a GPU **probe kernel** that
dynamically indexes the bound table and reports which resource it actually saw.
A CPU model predicts every probe result; any divergence (including use-after-recycle,
which recycle-poisoning turns into guaranteed divergence) fails the run.

Gates:

1. **Model correctness** — randomized alloc/copy/rebind/submit sequences across two
   command queues with forced page rollover; zero mismatches, zero use-after-recycle.
2. **Cost** — descriptor-update and page-encode CPU cost per descriptor; page-cache
   hit rate on unchanged tables (the "no full-table rebuild on common paths" evidence).
3. **Memory** — bounded page pool under sustained pressure (pool never grows past the
   in-flight watermark).

Deferred beyond spike scope: engine trace replay (needs real captured traces — Phase 1),
sampler heaps (same mechanics, second descriptor class), tier-limits survey on older
hardware.

## Results log

Dated notes in `results/`. Hardware baseline: MacBook Pro M2 Pro, 16 GB, macOS 26.5.
