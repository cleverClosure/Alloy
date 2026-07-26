# ROLLBACK-001 result 08 — content transport happy path

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `458fb65987f8892598ffaa9269224c084a79de76`

## Exact claim

`AlloyContentStore` fetches a caller-authorized SHA-256 descriptor from ordered
Foundation `URLSession` mirrors, stages the response below its durable
operation directory, verifies exact size and digest, and publishes it only
through the existing hard-link CAS path. A URL or filename never becomes
identity. A verification failure reports a named error, quarantines the
operation, and leaves `objects/` untouched.

## Implementation

- `Specs/TRANSPORT_V1.md` defines mirror order, staging, verification,
  publication, refusal, and persisted recovery states.
- `Specs/transport-record.v1.schema.json` fixes the canonical sidecar contract
  at version 1.0.
- Production networking uses Foundation only. Test fixtures bind exclusively
  to `127.0.0.1`.
- The transport operation sidecar protects valid in-flight staging from
  garbage collection.

## Both-direction controls

The happy-path suite proves:

1. a first mirror returning HTTP 503 is refused and the second configured
   mirror supplies the exact caller-authorized bytes;
2. successful bytes appear as one validated CAS object, transport staging is
   removed, and a later fetch reuses the object without another transfer;
3. the opposite fixture returns wrong bytes of the declared size and receives
   `digestMismatch`; one `.transport` quarantine entry is created and no object
   appears;
4. an unrelated abandoned download is swept while the valid live transport
   operation remains protected;
5. a death after CAS publication leaves a recoverable published sidecar, while
   retry validates the object and removes only the completed staging.

## Reproduce

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
```
