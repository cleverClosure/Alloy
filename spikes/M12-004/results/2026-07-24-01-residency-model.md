# M12-004 result 01 — unified-memory residency: bounded, verified, budget is advisory

**Author:** Tim Isaev
**Date:** 24 July 2026
**Hardware:** M2 Pro, 16 GB (ADR-0011 certified floor), macOS 26.5 · **Provenance:**
ADR-0012 discipline model, inputs in [PROVENANCE.md](../PROVENANCE.md).

## Verdict

```text
budget: recommended max 12124 MB, baseline usage 0.1 MB
aliasing: A@0 then B@0 written; A now reads 0xBB (overlap real, retire rule load-bearing)
eviction cache: 137 evictions, 109 rematerializations verified, 0 mismatches
long session: 20000 ops, peak 820 MB, baseline 0.1 -> 0.1 MB (delta 0.0 MB)
oversubscription: pushed 13184 MB (budget 12124), 0 alloc failures
post-release: metal allocated 0.1 MB, process footprint 3.5 MB
m12-004 residency ok
```

## What each phase established

- **Placement heaps + aliasing lifetime.** Two buffers placed at the same heap offset
  genuinely share memory (B's write observably destroys A's bytes) — so the model's
  retire-on-alias bookkeeping is load-bearing, proven by observation rather than
  assumed from documentation.
- **Budget reporting** synthesizes a `QueryVideoMemoryInfo`-shaped record from
  `recommendedMaxWorkingSetSize` (12.1 GB on the 16 GB floor) + `currentAllocatedSize`.
- **Pressure-aware eviction**: an LRU chunk cache (12×64 MB against a 40-chunk working
  set) evicted 137 times; every rematerialized chunk checksum-matched its original
  content — the regenerate-on-demand pattern works with zero corruption.
- **Long-session churn**: 20k random alloc/free cycles, peak 820 MB, allocated bytes
  returned to baseline exactly.
- **Oversubscription on unified memory: allocation never fails at budget.** The push
  cleared budget+1 GB (13.2 GB on a 16 GB machine) with zero allocator failures —
  Metal grants far past the recommended working set. **The budget is advisory;
  a Metal12 provider must self-police** (the eviction cache above is exactly that
  enforcement pattern). The evict-and-retry failure path therefore never fired at
  this scale and stays code-proven only; the graceful backstop that did matter is
  the `host_statistics64` system-floor bail-out.
- **Memory truly returns**: after releasing everything, Metal-allocated fell to
  0.1 MB and process footprint to 3.5 MB.

## The measurement lesson that almost lied to us

The first runs showed a 9.6 GB "baseline" and memory that never returned — which
looked exactly like driver-side pooling of freed buffers. It was ARC: buffer
references returned across the framework boundary landed in `main`'s never-draining
autorelease pool, pinning every chunk until exit. Per-phase `@autoreleasepool`
blocks flipped every number to clean. Two rules for all future Metal measurement
code: every phase gets its own pool, and any "the driver is hoarding memory"
hypothesis must first survive a footprint check against a pool-disciplined build.

## Doc-16 pass evidence

| Evidence | Result |
| --- | --- |
| Stable headroom | budget synthesis + self-policed cache under a 12.1 GB advisory ceiling |
| Bounded growth | churn delta 0.0 MB over 20k ops; post-release returns to baseline |
| Correct alias/lifetime | physical overlap proven; retire rule demonstrated necessary |
| Graceful degradation | system-floor bail-out guard; allocator failure shown unreachable at budget+1 GB on 16 GB — degradation is system pressure, not API failure |

## Honest limits

16 GB only (24/32/64 GB founder-hardware-gated); buffers only (no texture heaps);
allocation-failure recovery path unexercised because unified memory would not fail
at safe test scale; long-session trace is synthetic (real traces Phase 1).

## Build & run

`clang -fobjc-arc -O2 -o work/residency_model prototype/residency_model.m -framework
Metal -framework Foundation` — self-verifying, exit 0 = green.
