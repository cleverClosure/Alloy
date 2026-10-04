<!-- Author: Timur Isaev -->

# Alloy local content catalog 1.0

## Purpose and authority

`metadata/catalog.sqlite` is a query cache over the content store. It indexes
CAS objects, sealed generations, active/rollback/candidate references, and
persisted generation leases. Disk artifacts specified elsewhere remain the
only source of truth. A catalog row never authorizes publication, activation,
launch, retention, or deletion.

The catalog uses the operating system's SQLite3 library. Its schema is
[`catalog.v1.sql`](catalog.v1.sql), with SQLite `application_id` `0x414c4c59`
(`ALLY`), `user_version` `1`, and semantic schema version `1.0`. A reader MUST
reject an unrecognized identity or version and rebuild from disk rather than
migrating it as authoritative state.

## Indexed records

The 1.0 schema contains:

- `objects`: SHA-256 digest, actual regular-file size, and refcount;
- `generations` and `generation_layers`: game/generation identity, manifest
  digest, and the manifest's ordered layer digests;
- `generation_references`: every active, rollback, and candidate reference;
- `leases` and `lease_objects`: every persisted lease, exact process identity,
  generation, and sorted unique object set;
- `inventory`: one transactionally maintained summary row.

An object's `refcount` is the number of layer entries across all sealed
generation manifests. It is not a garbage-collection decision by itself:
reference and lease roots still determine reachability. The summary row makes
inventory counts and total object bytes a single-primary-key lookup, without a
filesystem walk or aggregate table scan.

Catalog generation scans ignore only staging directory names derived from a
validated, nonterminal activation journal. A caller-visible generation is not
ignored merely because its identifier begins with a dot or ends in
`.staging`. Internal staging is incomplete publication state, not a sealed
generation. Unknown reference or lease entries and other malformed,
nonregular, or schema-invalid disk entries fail the scan closed.

## Maintenance and locking

All consistency checks, rebuilds, and maintenance transactions execute while
holding `metadata/content-store.lock`, the same cross-process exclusive lock
used by activation, leases, and garbage collection.

Normal mutation paths reconcile a fresh disk snapshot into the catalog in one
`BEGIN IMMEDIATE` transaction. The transaction replaces the modeled row set
and its summary together. SQLite foreign keys are enabled, rollback journaling
is used, and synchronous mode is `FULL`.

The public open path MUST:

1. build the catalog when it is absent;
2. validate all three schema identifiers;
3. compare the catalog with a fresh disk snapshot;
4. replace the catalog from disk if it is invalid or divergent.

Recovery paths MUST reconcile again after they finish replaying journals.
Every public operation that changes objects, generations, references, or
leases MUST reconcile before releasing the store lock.

## Consistency report

The checker canonicalizes both disk and catalog records and computes two set
differences:

- `catalogAhead`: rows claimed by SQLite but absent from disk truth;
- `diskAhead`: disk records absent from SQLite.

A changed row appears once in each direction. A clean store reports exactly
zero entries. A missing catalog is reported as disk-ahead even when the store
is otherwise empty, so absence cannot be mistaken for verified consistency.

The canonical diagnostic dump is sorted-key JSON with arrays ordered by
primary key and a final newline. SQLite page order, freelists, journal bytes,
timestamps, and database file identity are deliberately excluded. Deleting
and rebuilding a catalog for unchanged disk state MUST yield a byte-identical
canonical dump.

## Process-death behavior

Catalog maintenance exposes these process-death points:

- `before-catalog-maintenance`;
- `after-catalog-reconcile`, before commit;
- `after-catalog-commit`.

Death before commit leaves the previous transaction or an invalid/empty new
cache; SQLite rollback and the next open's consistency check repair it. Death
after commit leaves a complete catalog. No point changes disk truth.

## Evolution

Version 1 readers accept only the exact schema above. Any table, constraint,
refcount semantic, canonical-dump semantic, or authority change requires a new
versioned schema and an explicit compatibility policy.
