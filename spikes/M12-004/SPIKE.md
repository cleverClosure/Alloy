# SPIKE-M12-004 — Unified-memory residency model

**Author:** Tim Isaev
**Status:** Active (started 24 July 2026)
**Canonical definition:** [doc 16 §M12-004](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md)
**Provenance:** [ADR-0012 discipline model](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md) · log in [PROVENANCE.md](PROVENANCE.md)

**Hypothesis:** a virtual D3D12 memory model can avoid duplicate staging and pressure
collapse across supported memory classes.

## Method

Native macOS prototype on the 16 GB certified floor (ADR-0011):

1. **Committed vs placed** — dedicated MTLBuffers vs placement-heap sub-allocations;
   an aliasing pair placed over the same heap range proves the lifetime rule: after
   the second resource activates, the first's bytes are gone (measured, not assumed),
   so the model's retire-on-alias bookkeeping is load-bearing.
2. **Budget reporting** — synthesize a `QueryVideoMemoryInfo`-style record from
   `recommendedMaxWorkingSetSize` + `currentAllocatedSize`.
3. **Pressure-aware eviction** — a chunk cache with regenerable, checksummed content
   evicts LRU under a budget fraction and rematerializes on demand; every
   rematerialization must checksum-match.
4. **Long-session churn** — tens of thousands of random alloc/free cycles; allocated
   bytes must return to baseline (bounded growth).
5. **Oversubscription** — push past the recommended working set with a hard
   `os_proc_available_memory` bail-out; allocation failure must be handled by
   evict-and-retry, never a crash; the degradation is recorded.

16/24/32/64 GB matrix beyond the 16 GB floor is founder-hardware-gated and out of
this prototype's scope.

## Results log

Dated notes in `results/`. Hardware baseline: MacBook Pro M2 Pro, 16 GB, macOS 26.5.
