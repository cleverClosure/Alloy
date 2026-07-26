# Content transport v1

Author: Timur Isaev

## Contract

Transport accepts a caller-authorized SHA-256 `LayerDescriptor`; it never
discovers trust metadata. Mirrors are attempted in caller order. For a base URL
`BASE` and digest `sha256:HEX`, the object URL is `BASE/sha256/HEX`.

Every fetch stages below `downloads/OPERATION_ID/`. `transport.json` is the
canonical, versioned operation record and the payload is
`000-HEX.part`. JSON is encoded with sorted keys and without escaped slashes.
The record is durable before the first request. When the caller does not supply
an operation ID, `fetch-HEX` is used, so a new process deterministically finds
the same partial. `metadata/transport-locks/OPERATION_ID.lock` serializes
fetchers for that operation while the content-store lock remains available to
garbage collection.

Only `http` and `https` base URLs are accepted. Production code uses Foundation
`URLSession` without third-party transport packages. Tests use fixture servers
bound only to `127.0.0.1`.

## Publication and refusal

The staged byte count must exactly equal the caller's declared size and its
SHA-256 must exactly equal the caller's digest. Verification precedes every CAS
mutation. Successful bytes enter `objects/sha256/HH/REST` through the existing
durable hard-link publication path, so an already valid object is reused.

A size or digest mismatch moves the complete operation directory to a uniquely
named `.transport` directory under `quarantine/`, returns the corresponding
named `ContentTransportError`, and publishes no object.

HTTP and connection failures advance to the next mirror. Exhaustion returns
`allMirrorsFailed` with the ordered refusal descriptions.

## Persisted states

- `downloading`: the durable operation exists and a request may be in flight.
- `downloaded`: a complete response is durable in the staging directory.
- `verified`: declared size and SHA-256 have passed.
- `published`: the CAS link exists; the operation directory can be removed.

Schema: [`transport-record.v1.schema.json`](transport-record.v1.schema.json).

## Resume protocol

Response bytes are streamed directly to the partial file. The implementation
splits arbitrary `URLSession` callback chunks at fixed 64 KiB boundaries. At
each boundary it writes the prefix, calls `fsync`, atomically checkpoints
`byteCount`, and only then exposes the `after-transport-stream-chunk` fault
point. The final declared byte count is checkpointed only after HTTP completion
succeeds, so an oversized or failed response cannot become recoverably
complete. Disk bytes beyond the last checkpoint are truncated before a retry.

A nonzero checkpoint sends `Range: bytes=BYTE_COUNT-`. A `206` response is
accepted only when `Content-Range` starts at that exact byte, ends at
`expectedSize - 1`, and declares `expectedSize` as the total. A server that
answers a resumed request with `200` first checkpoints a safe reset to zero,
then durably truncates the partial before consuming the full response. A kill
between those operations leaves only excess bytes, which the next recovery
truncates to the zero checkpoint. Thus both resumed and clean restart paths
produce the same authorized byte sequence as an uninterrupted fetch.

The operation lock is never the content-store lock. Publication takes the
content-store lock only after the full payload is durable and verified.
Garbage collection recognizes a valid transport sidecar and preserves that
download directory while it sweeps unrelated staging.

## Recovery boundaries

The transport fault points are:

- `after-transport-stream-chunk`
- `before-transport-verification`
- `after-transport-verification`
- `before-transport-publication`
- `after-transport-publication`

Recovery from `downloading` resumes the durable prefix, recovery from
`downloaded` re-verifies, recovery from `verified` republishes through the
idempotent CAS path, and recovery from `published` validates the object and
removes staging. Publication therefore has exactly-once observable contents
even when the final cleanup is interrupted.
