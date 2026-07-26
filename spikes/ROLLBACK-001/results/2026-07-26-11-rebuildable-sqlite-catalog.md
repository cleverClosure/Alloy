# ROLLBACK-001 result 11 — rebuildable SQLite catalog

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `df88debee606b9ddfe4f6e5728f6655d52b1cdfb`

## Exact claim

`AlloyContentStore` maintains `metadata/catalog.sqlite` as a rebuildable cache
over disk truth. It indexes objects with size and generation-layer refcount,
sealed generations with ordered object membership, all generation references,
and persisted leases with exact process identity. A singleton inventory row
answers the package's summary inventory query without a filesystem walk.

The cache uses the operating system SQLite3 module and no package dependency.
`Specs/CATALOG_V1.md` and `Specs/catalog.v1.sql` freeze its identity,
constraints, refcount meaning, canonical diagnostic form, authority boundary,
and death semantics.

## Automatic lifecycle integration

Opening a store while holding `metadata/content-store.lock` creates a missing
catalog and replaces an invalid or divergent catalog from disk truth. Opening
does not treat catalog rows as authority and does not require an explicit
maintenance call from the caller.

The production mutation paths reconcile before releasing that same lock:

- successful activation and explicit journal recovery;
- lease acquisition, release, and stale-lease pruning;
- garbage collection, including generation, object, download, and quarantine
  sweeps;
- transport publication through the shared hard-link CAS path;
- planning queries that can prune stale leases while computing reachability.

The current-main compatibility fixture, generated before the catalog existed,
opens with three objects, two generations, two references, four generation
layer references, and no leases. Explicit recovery leaves its canonical dump
unchanged. This proves catalog creation does not migrate or rewrite the
versioned source artifacts.

The disk scanner ignores only the exact staging directory recorded by a
nonterminal activation journal. A caller-visible generation named
`.release.staging` is indexed normally. Unknown reference and lease directory
entries fail scanning closed.

## Disk-only truth and convergence

The positive test builds generations A, B, and C with one shared object,
leases B, and runs garbage collection over unreachable A and a seeded
quarantine entry. Each public mutation is checked for automatic zero
divergence. The resulting catalog contains three objects, two generations, two
references, one lease, and four generation-layer references.

The test captures the incrementally maintained canonical dump, deletes
`catalog.sqlite`, reopens the store for an automatic disk-only rebuild, and
compares the new dump byte for byte. A subsequent forced rebuild produces the
same bytes again. SQLite page layout is not part of this claim; the canonical
sorted-key JSON record stream is.

## Both-direction controls

- Clean control: a maintained store reports exactly zero divergence.
- Catalog-ahead control: a valid but invented object row is inserted directly
  into SQLite.
- Disk-ahead control: a valid unreferenced object is installed directly in its
  digest-addressed disk location.
- Exact comparison: `catalogAhead` equals the invented object row plus the old
  inventory row, while `diskAhead` equals the disk-only object row plus the
  replacement inventory row. The test compares both complete sorted arrays,
  not substring matches or nonzero counts.
- Repair control: reopening replaces the divergent cache, reports exact zero,
  and yields the same canonical dump as a subsequent forced rebuild.
- Invalid control: non-SQLite catalog bytes are detected and replaced while
  opening an otherwise empty store.

Changed keyed rows intentionally appear in both sets: the stale catalog value
is catalog-ahead and the replacement disk value is disk-ahead.

## Process-death boundaries

Focused tests inject termination through both incremental reconciliation and
missing-catalog replacement:

1. before catalog maintenance starts;
2. after all rows are reconciled inside the SQLite transaction but before
   commit;
3. after the durable commit.

Every case reopens the same store, runs open-time detection/rebuild, reaches
exact-zero consistency, and produces the expected canonical dump. The first
two cases prove old, missing, empty, or rolled-back cache recovery; the third
proves a committed cache is already complete. The replacement control covers
the destructive rebuild path separately from an update to an existing valid
catalog.

These points are exposed as
`ContentStore.catalogMaintenanceFaultPoints` for the package's process-death
matrix. The production matrix uses `_exit(97)` in the faulting process, opens
the same root in later processes, and requires catalog consistency in its
activation, garbage-collection, and transport verification paths.

## Recorded validation

The focused run passed 11 catalog and compatibility tests. Its two
parameterized maintenance tests additionally passed six catalog fault cases:
all three boundaries on both incremental reconciliation and missing-catalog
replacement. Coverage
includes automatic open repair, activation, recovery, leases, garbage
collection, transport publication, canonical rebuild convergence, exact
bidirectional divergence, strict scanner behavior, and the current-main
fixture.

The real-process fault matrix passed all 37 cases: 35 production fault points,
including all three catalog transaction boundaries, plus the ignored-Range
restart-death and failed-health rollback controls.

```text
PASS before-catalog-maintenance
PASS after-catalog-reconcile
PASS after-catalog-commit
SUMMARY cases=37
```

## Reproduce

```sh
swift test --disable-sandbox --package-path runtime/content-store \
  --filter 'Catalog|Compatibility'
runtime/content-store/run-fault-matrix.sh
```
