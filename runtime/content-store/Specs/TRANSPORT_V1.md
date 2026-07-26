# Content transport v1

Author: Timur Isaev

## Contract

Transport accepts a caller-authorized SHA-256 `LayerDescriptor`; it never
discovers trust metadata. Mirrors are attempted in caller order. For a base URL
`BASE` and digest `sha256:HEX`, the object URL is `BASE/sha256/HEX`.

Every fetch stages below `downloads/OPERATION_ID/`. `transport.json` is the
canonical, versioned operation record and the payload is
`000-HEX.part`. JSON is encoded with sorted keys and without escaped slashes.
The record is durable before the first request.

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
