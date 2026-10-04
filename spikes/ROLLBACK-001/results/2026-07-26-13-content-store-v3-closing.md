# ROLLBACK-001 result 13 — content store v3 closing record

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `df88debee606b9ddfe4f6e5728f6655d52b1cdfb`

## Verdict

Pass. `AlloyContentStore` now owns resumable, integrity-checked transport and a
rebuildable SQLite inventory in addition to its journaled CAS, atomic
generation lifecycle, exact-process leases, garbage collection, and disk
planning. The new behavior preserves every existing persisted v1 contract.

## Backward compatibility

`Tests/Fixtures/main-21136e4-store/` was created by the unmodified source at
commit `21136e49b9909349800e2b355076a3c8023a617e`. It predates transport
sidecars, transport locks, leases, and `metadata/catalog.sqlite`. It contains:

- active generation B and rollback generation A;
- one layer shared across both generations and one unique layer each;
- three CAS objects and two terminal activation journals;
- a save sentinel outside immutable generations;
- no catalog.

The v3 code opens that disk-only fixture without source migration and builds a
catalog containing three objects, two generations, two references, four
generation-layer memberships, and no leases. The consistency report is exact
zero on first open. Explicit recovery leaves the canonical catalog dump
byte-identical, both references and all three objects validate, the save
sentinel is unchanged, reinstall planning requires zero bytes, and collection
reports exact zero with and without a two-object lease. Lease acquisition and
release update the catalog to one and then zero lease rows without divergence.

No prior manifest, journal, reference, or save artifact is rewritten. Transport
records and the SQLite catalog are independently versioned additions; the
catalog is a disposable cache over those source artifacts, never a migration
authority.

## Guarantees now implemented

- caller-authorized digest and size identity for every layer;
- immutable, non-overwriting CAS publication with corrupt-collision
  quarantine;
- canonical generation manifests and atomic active, rollback, and candidate
  references;
- durable activation journals and idempotent recovery at every lifecycle
  boundary;
- save separation from immutable generations and cleanup traversal;
- exact-process generation leases with explicit release and dead-holder
  reclamation;
- restartable mark-and-sweep over every game, live lease, incomplete
  activation, and live transport operation;
- deduplicated capacity planning and exact-or-deferred category reclaim
  reporting;
- ordered-mirror `URLSession` transport with durable 64 KiB checkpoints,
  exact HTTP Range resume, clean no-Range restart, strict size and digest
  verification, quarantine, bounded redirects, and deadlines;
- refusal of wrong, truncated, oversized, stalled, length-disagreeing, and
  redirect-loop responses before publication;
- process-death recovery before and after verification, publication, GC, and
  catalog transactions;
- a system-SQLite inventory for objects, generations, references, leases, and
  constant-time counts;
- automatic missing/invalid/divergent catalog detection and disk-only rebuild,
  with canonical convergence and exact bidirectional consistency reporting;
- deterministic two-process ordering for lease/GC, activation/GC, and
  downloader/GC races;
- seeded model-oracle stress across publish, activate, rollback, lease,
  release, sweep, and kill/resume download operations.

## Ordered evidence

The v3 gate records are:

1. `2026-07-26-08-content-transport-happy-path.md`
2. `2026-07-26-09-resumable-content-transport.md`
3. `2026-07-26-10-hostile-content-server.md`
4. `2026-07-26-11-rebuildable-sqlite-catalog.md`
5. `2026-07-26-12-everything-races-everything.md`
6. this compatibility and closing record.

The final recorded validation is:

```text
swift test: 62 tests passed
fault matrix: SUMMARY cases=37
concurrency matrix: SUMMARY cases=6
stress matrix: SUMMARY seeds=85 740085 12648430 20260726 steps_per_seed=48 total_steps=192
strict lint: pass
```

## Boundaries retained

The package README retains exactly the remaining three deliberate boundaries:

- TUF/DSSE authorization and Developer ID verification;
- hostile archive extraction and file-table validation;
- Zstandard decompression and APFS tree cloning.

No trust, archive, compression, or filesystem-cloning behavior is implied by
the transport or catalog work.

## Work provenance

The implementation remained in the repository task lane for issue #87 and
touched only `runtime/content-store/` and
`spikes/ROLLBACK-001/results/`. No ADR-0012 excluded source was consulted.

## Reproduce

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
tools/lint.sh
```
