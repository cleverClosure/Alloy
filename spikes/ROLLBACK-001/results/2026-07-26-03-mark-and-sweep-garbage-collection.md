# ROLLBACK-001 result 03 — mark-and-sweep garbage collection

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `21136e49b9909349800e2b355076a3c8023a617e`

## Exact claim

Under the store's cross-process exclusive lock, `AlloyContentStore` first
recovers every interrupted activation, then marks the active, rollback, and
candidate generation of every game plus every exactly live lease. It removes
only generation directories and CAS objects outside that set, together with
abandoned download and quarantine entries. A process may die after any
destructive step; the next pass recomputes marks and completes safely.

## Safety ordering

Recovery precedes marking so objects published by a killed activation cannot
be mistaken for garbage before their journal reaches a reference. Unreachable
generation hard links are removed before their CAS names, allowing the object
payload's final link to be reclaimed. Mark state is never reused across lock
acquisitions or process restarts.

Malformed reference directories and malformed or unsupported leases stop the
sweep. Uncertain process liveness keeps lease roots. Saves remain under
`volumes/`, a tree the collector never traverses.

Generation removal changes directory permissions only. It never changes modes
on materialized layer files because those files share inodes with CAS objects
and other generations. Symlinks and malformed CAS layouts stop the sweep
without being followed.

## Both-direction controls

- Positive: after generations A → B → C, A and its unique CAS object are
  collected; seeded abandoned download and quarantine entries are removed.
- Negative: a fully referenced store returns the exact zero result.
- Root breadth: active, rollback, candidate, another game's active reference,
  and a live lease all preserve their generations and objects.
- Release control: after the lease protecting A is explicitly released, the
  same sweep removes A.
- Integrity controls: a schema-valid lease with a truncated digest set fails
  before deletion, and a reachable dot-prefixed generation ID survives.
- Inode control: removing A leaves the shared CAS object and both reachable
  generation links at mode `0444`.

## Process-death boundaries

The functional suite injects termination after mark, after each generation,
object, download, and quarantine removal, and after each sweep stage. Every
case reopens the store, sweeps twice, preserves active C and rollback B, and
ends at exact zero.

The production fault-probe matrix exercises the same boundaries with
`_exit(97)` in a separate process in addition to all original activation
boundaries.

## Reproduce

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
```
