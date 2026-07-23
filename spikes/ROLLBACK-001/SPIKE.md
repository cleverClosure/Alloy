# SPIKE-ROLLBACK-001 — Transactional generation lifecycle

**Author:** Timur Isaev
**Status:** Closed 24 July 2026 — Phase-0 prototype passed
**Canonical definition:** [doc 16 §4](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md)
· validates [ADR-0007](../../docs/adr/ADR-0007-content-addressed-immutable-runtimes.md)

**Hypothesis:** A user-space runtime store on APFS can publish verified content-addressed
objects, materialize immutable generations, switch the active generation atomically, and
recover after process death at every lifecycle boundary without changing save data.

## Method

The prototype in [`prototype/`](prototype/) exercises:

```text
download → verify → publish CAS → materialize
→ prepare candidate → record rollback → switch active reference
→ health window → retain rollback / collect candidate
```

Every mutating stage has two injected process-death points:

1. after the filesystem action but before the journal advances;
2. after the journal advances.

The harness starts from a healthy generation, writes a save sentinel outside all runtime
generations, terminates the updater with `_exit(97)` at each point, starts a fresh recovery
process, and verifies the active reference, object digest, materialized manifest, rollback
reference, and save sentinel.

## Pass evidence

- after every injected termination, the active reference names either the previous complete
  generation or the complete candidate;
- recovery is idempotent and never activates an unverified or incomplete generation;
- a failed health window restores the previous active reference;
- saves remain byte-identical across update, recovery, rollback, and candidate cleanup;
- duplicate payloads reuse one verified CAS object;
- a digest mismatch or corrupt local object cannot activate.

## Scope

This is a Phase-0 lifecycle proof, not the Phase-1 production store. It deliberately omits
network transport, TUF/DSSE verification, archive extraction, SQLite, APFS clonefile
materialization, leases, and production garbage collection. Those remain required by
EPIC-003.

## Results

The prototype passed all 18 process-death boundaries, failed-health rollback, save
preservation, CAS deduplication, digest rejection, local-corruption quarantine, path
validation, and idempotent recovery checks. See
[`results/2026-07-24-01-transactional-generation-lifecycle.md`](results/2026-07-24-01-transactional-generation-lifecycle.md).
