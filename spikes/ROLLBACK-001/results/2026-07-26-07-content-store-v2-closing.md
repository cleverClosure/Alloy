# ROLLBACK-001 result 07 — content store v2 closing record

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `21136e49b9909349800e2b355076a3c8023a617e`

## Verdict

Pass. `AlloyContentStore` now owns proof-scope object leases, crash-safe
mark-and-sweep garbage collection, dedup-aware disk planning, and
cross-process launch/writer/collector coordination. The new behavior preserves
the existing generation-manifest and activation-journal 1.0 semantics.

## Backward compatibility

`Tests/Fixtures/main-21136e4-store/` was created by the unmodified source at
commit `21136e49b9909349800e2b355076a3c8023a617e` before the v2 implementation.
Its committed sibling generator records the full input procedure, and a mode
manifest restores the base store's `0444`, `0555`, and `0600` modes after
Git's mode normalization. It contains:

- active generation B and rollback generation A;
- one layer shared across both generations and one unique layer each;
- three CAS objects and two terminal activation journals;
- a save sentinel outside immutable generations.

The new code opens the fixture without migration, recovers it idempotently,
validates both references and all three objects, reads the byte-identical save,
plans reinstallation of B at exactly zero additional CAS bytes, reports zero
reclaimable bytes, acquires/releases a two-object lease, and runs an exact-zero
sweep with and without that lease.

No existing persisted schema changed. The only new persisted artifact is the
generation lease, independently versioned and specified by
`Specs/LEASES_V1.md` and `generation-lease.v1.schema.json`.

## Guarantees now implemented

- immutable digest-addressed objects and canonical generation manifests;
- atomic active, rollback, and candidate references;
- durable, replayable activation journals and idempotent recovery;
- save separation from every activation and cleanup traversal;
- exact-process generation leases with explicit release and dead-holder
  reclamation;
- mark-and-sweep roots spanning all games and live leases;
- deletion of unreachable generation hard links before CAS objects;
- cleanup restartability after real process death at every committed boundary;
- deduplicated capacity planning, named refusal, and exact-or-deferred
  category reclaim reporting without hard-link double counting;
- deterministic two-process ordering for launch/GC and activation/GC races;
- seeded reachability-oracle stress across publish, activate, rollback, lease,
  release, and sweep.

## Evidence

The ordered gate records are:

1. `2026-07-26-02-generation-leases.md`
2. `2026-07-26-03-mark-and-sweep-garbage-collection.md`
3. `2026-07-26-04-disk-planning.md`
4. `2026-07-26-05-two-process-coordination.md`
5. `2026-07-26-06-seeded-adversarial-stress.md`
6. this compatibility and closing record.

Verification commands:

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
tools/lint.sh
```

## Boundaries retained

The store still does not claim:

- resumable transport;
- TUF/DSSE authorization or Developer ID verification;
- hostile tar archive extraction and file-table validation;
- Zstandard decompression or APFS clone materialization;
- SQLite catalog integration.

These remain explicit in the package README.

## Work provenance

The implementation was performed in the repository's `codex` task lane for
issue #85. No ADR-0012 excluded source was consulted; the task remained inside
`runtime/content-store/` and `spikes/ROLLBACK-001/results/`.
