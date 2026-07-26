# ROLLBACK-001 result 05 — deterministic two-process coordination

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `21136e49b9909349800e2b355076a3c8023a617e`

## Exact claim

Two independent `alloy-content-store-fault-probe` processes can race launch,
lease release, activation, and collection without losing a leased generation
or exposing a partly activated one. The store-wide `flock` orders every mark
snapshot against lease and journal publication. Callers outside the lock see
only a completed operation or a safe refusal after collection.

## Deterministic harness

`runtime/content-store/run-concurrency-matrix.sh` forces four named
interleavings. Processes publish marker files at exact library fault
boundaries and block on `kqueue` filesystem events until the harness publishes
the continuation marker. Before each blocked-contender marker, the contender
performs a nonblocking `flock` and requires `EWOULDBLOCK`; the owner cannot
continue until that proof marker exists. There are no timing sleeps,
scheduling guesses, or thread substitutes.

1. **lease-before-sweep:** a launcher acquires A, references advance through B
   and C, and another process sweeps. A survives while leased and is collected
   only after explicit release.
2. **release-after-mark:** GC pauses after marking the live A lease. Release is
   requested while GC owns the lock; A survives that pass and is collected by
   the next pass.
3. **gc-before-writer:** GC pauses after mark while a real writer announces D
   and blocks on the lock. GC finishes, D activates, recovery is idempotent,
   and its journal is complete.
4. **writer-before-gc:** D pauses after its CAS publication action while
   holding the lock. A real collector announces and blocks. D completes its
   durable journal before GC marks; D remains valid after two recovery passes.

## Controls and result

Both lease cases prove the protected and released directions. Both
writer/collector cases reverse lock acquisition order at named boundaries.
Every case validates the resulting generation through its canonical manifest
and CAS digests. The writer cases verify the save sentinel and zero incomplete
operations after two fresh recovery passes, require no candidate reference,
and validate rollback when present.

```text
PASS lease-before-sweep
PASS release-after-mark
PASS gc-before-writer
PASS writer-before-gc
SUMMARY cases=4
```

## Reproduce

```sh
runtime/content-store/run-concurrency-matrix.sh
```
