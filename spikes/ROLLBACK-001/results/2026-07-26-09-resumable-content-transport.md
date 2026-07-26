# ROLLBACK-001 result 09 — resumable content transport

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `458fb65987f8892598ffaa9269224c084a79de76`

## Exact claim

`AlloyContentStore` streams a caller-authorized object directly into its
versioned partial-download file with a fixed 64 KiB durable checkpoint. A new
process resumes the exact persisted prefix with HTTP Range, validates a strict
`206 Content-Range`, and converges to the same SHA-256 object bytes as an
uninterrupted fetch. Arbitrary callback chunk sizes never write or checkpoint
beyond the declared object size.

The final declared byte count is persisted only after HTTP completion succeeds.
An oversized, truncated, or failed response therefore cannot be mistaken for a
recoverably complete object. A mirror change preserves the newest on-disk
checkpoint. A server that answers a resumed request with `200` is handled by a
crash-safe reset record followed by a durable truncate, never by splicing its
full response onto the old prefix.

## Implementation

- `Specs/TRANSPORT_V1.md` fixes the Range, checkpoint, reset, lock-order, and
  recovery contract without changing the v1 sidecar schema.
- `TransportStreamingDelegate` uses a bounded `URLSessionDataDelegate`; the
  earlier buffered whole-response implementation has been removed.
- A stable `metadata/transport-locks/OPERATION_ID.lock` serializes same-operation
  fetchers without holding the content-store lock across network I/O.
- The five transport lifecycle boundaries are exported as
  `ContentStore.transportFaultPoints` and run through the production fault
  probe. The matrix server is Python standard library only, binds to
  `127.0.0.1`, and supports deterministic byte ranges.
- Publication still uses the pre-existing hard-link CAS path. A completed retry
  leaves one object link and removes its transport staging directory.

## Both-direction controls

The resume suite and process-death matrix prove:

1. a killed full request leaves exactly one 64 KiB durable prefix, and retry
   sends `Range: bytes=65536-`; the final object equals the authorized payload;
2. the uninterrupted side of the same fixture returns the identical digest;
3. a Range-capable server appends only its validated suffix, while a server
   ignoring Range resets to zero and transfers the full object cleanly;
4. a real process death during that decreasing reset leaves excess bytes that
   the next process truncates and then completes without a corrupt splice;
5. a truncated first mirror cannot roll back its checkpoint when fallback
   reaches a healthy second mirror;
6. deaths midstream and before/after both verification and publication all
   converge to one valid object; the no-death controls complete directly;
7. a live transport sidecar protects staging from collection, while unrelated
   abandoned staging is removed;
8. a caller-authorized zero-byte object follows the network completion path and
   is subsequently reused from CAS.

## Recorded run

The production process-death matrix passed all 34 cases:

```text
PASS after-transport-stream-chunk
PASS before-transport-verification
PASS after-transport-verification
PASS before-transport-publication
PASS after-transport-publication
PASS ignored-range-restart-death
SUMMARY cases=34 elapsed_seconds=4
```

The matrix uses `_exit(97)` rather than a caught Swift error, reopens the store
in a separate process, retries the same operation ID and base URL, then requires
CAS reuse, byte identity, exactly one object, and no completed staging.

## Reproduce

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
```
