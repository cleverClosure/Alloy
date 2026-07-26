# Gate 1 — content transport happy path

Author: Timur Isaev

## Result

The content store now fetches caller-authorized descriptors from ordered
Foundation `URLSession` mirrors, stages every response under a durable operation
record, verifies exact size and SHA-256, and enters the CAS through the existing
hard-link publisher.

The loopback acceptance fixtures prove first-mirror success, ordered fallback,
valid-object reuse, and quarantined digest refusal. A rejected response creates
no CAS object.

## Evidence

- `Specs/TRANSPORT_V1.md`
- `Specs/transport-record.v1.schema.json`
- `TransportTests.swift`
- `swift test --disable-sandbox --package-path runtime/content-store`
- `runtime/content-store/run-fault-matrix.sh`
- `runtime/content-store/run-concurrency-matrix.sh`
- `runtime/content-store/run-stress-matrix.sh`
