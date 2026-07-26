# ROLLBACK-001 result 04 — dedup-aware disk planning

**Author:** Timur Isaev
**Date:** 26 July 2026
**Status:** Gate 3 passed
**Repository base:** `21136e4`; implementation and this evidence record are one change set
**Host:** MacBook Pro M2 Pro, 16 GB, macOS 26.5.2, APFS, Swift 6.2.4

## Verdict

Pass. The content store can report the additional immutable bytes an operation needs before it
starts, count each unique digest once, treat a valid object already present in the CAS as zero
additional bytes, and refuse a plan that exceeds a caller-supplied available-byte figure with
an `InsufficientDiskSpaceError` carrying the exact required and available counts.

The public reclaim estimate reports logical bytes by unreachable generation
files, CAS objects, abandoned downloads, and quarantine leftovers. It derives
reachability from all active, rollback, and candidate references, every live
lease, and every valid nonterminal journal.

## Implemented surface

- `preflightDiskSpace(for:)` validates descriptors, collapses duplicate digests, verifies
  purportedly present CAS objects, and returns counts plus `additionalBytesRequired`;
- `DiskSpacePlan.requireFits(availableBytes:)` and the available-byte preflight overload perform
  the refusal before an operation starts;
- `activate(...availableBytes:)` repeats that check under the operation lock
  before creating a journal or download directory;
- activation stages one payload per missing digest and stages nothing for a
  valid object already in CAS, so the execution path matches the plan;
- `InsufficientDiskSpaceError` exposes `requiredBytes` and `availableBytes`;
- `estimateGarbageCollectionReclaim()` reports generation, CAS-object,
  abandoned-download, quarantine, and total logical bytes, with category
  counts;
- the reporter consumes the garbage collector's canonical reference-and-live-lease mark set;
- valid nonterminal journals protect their downloads, published CAS objects,
  and materialized generations;
- `deferredOperationCount` and `isExact` expose when the report is a
  conservative lower bound pending recovery; it is exact with no deferred
  operation;
- an unreadable journal makes both estimation and collection fail closed;
- an internal `additionalReachableDigests` hook admits future roots without duplicating the
  canonical mark logic;
- unique generation files are counted, while generation hard links are not
  counted as a second copy of CAS content.

The preflight byte model is the additional immutable CAS payload. Temporary
transport overhead, filesystem metadata, and reserve policy remain separate.
The reclaim model counts regular-file bytes whose names the sweep can actually
free and avoids hard-link double counting.

## Both-direction controls

The committed tests establish these positive and negative controls:

1. an empty store plans the sum of two unique payloads when each descriptor appears twice;
2. after publishing one payload, only the other payload contributes additional bytes;
3. after publishing both payloads, the same re-install plans exactly zero additional bytes;
4. a plan with one byte less than required throws the named error with exact counts;
5. the same plan with exactly the required bytes is accepted;
6. activation one byte short is refused with no journal or active reference,
   while exact capacity activates;
7. duplicate missing inputs stage one payload at exact capacity, and a
   zero-byte reinstall creates no download payload before recovery;
8. generation, CAS, abandoned-download, and quarantine categories match their
   sweep targets without counting shared hard links twice;
9. published objects and materialized generations owned by nonterminal
   journals remain protected and mark the estimate as deferred;
10. after recovery, the exact estimate equals the collection's reported bytes,
    and the next estimate is zero;
11. an unreadable journal makes estimation and collection return the same
    `invalidJournal` error;
12. adding an otherwise unreachable digest through the internal hook removes
    it from the CAS estimate;
13. an unreferenced generation remains protected while its process lease is
    live, then appears by generation and CAS category after release.

## Functional tests

Run:

```sh
swift test --disable-sandbox --package-path runtime/content-store
```

The package test suite passed, including all eight disk-planning and
reclaim-estimate tests.

## Limits carried forward

- The available-byte figure comes from the caller so policy can select the appropriate APFS
  capacity key and reserve margin; this gate does not silently choose either.
- The planner reports additional durable CAS payload. Resumable transport staging and a
  configurable safety reserve remain caller policy.
- Reclaim totals are logical regular-file bytes selected by the sweep.
  Directory metadata, symbolic-link storage, and filesystem-specific block
  allocation are not claimed.
- The reporter shares the live-lease and reference-root model with collection, but gate 2 owns
  deletion and its process-death proof.
