# SPIKE-M12-002 — Barriers, resource state, and queue scheduling

**Author:** Tim Isaev
**Status:** Active (started 24 July 2026)
**Canonical definition:** [doc 16 §M12-002](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md)
**Provenance:** [ADR-0012 discipline model](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md) · log in [PROVENANCE.md](PROVENANCE.md)

**Hypothesis:** a conservative state tracker can be optimized into a correct Metal
synchronization plan without serializing modern engines.

## Method

Native macOS prototype in two legs:

1. **Model leg (the heart).** Randomized D3D12-style command streams — transitions,
   UAV and aliasing barriers, reads/writes at per-subresource granularity on two
   queues — compiled two ways: a **conservative** plan (order everything that touches
   the same resource) and an **optimized** plan (per-subresource last-access tracking,
   read-read elision, and per-queue vector clocks that skip edges already implied
   transitively). Ground truth is a hazard graph built independently from the raw
   access sequence; a plan passes only if every hazard edge is covered by reachability
   through the emitted order (program order + fence/event edges). Metric: syncs
   eliminated by the optimized plan at zero uncovered hazards over many random streams.
2. **Execution leg.** A representative plan mapped to real Metal primitives —
   `MTLFence` within a queue, `MTLSharedEvent` across queues — with self-checking
   writer/reader kernels proving the plan orders real GPU work, plus a wall-clock
   demonstration that independent work on the two queues actually overlaps (the
   "without serializing" half of the hypothesis).

Deferred beyond spike scope: real engine trace replay (needs captures — Phase 1),
render-target/texture-specific barrier classes, three-plus queues.

## Results log

Dated notes in `results/`. Hardware baseline: MacBook Pro M2 Pro, 16 GB, macOS 26.5.
