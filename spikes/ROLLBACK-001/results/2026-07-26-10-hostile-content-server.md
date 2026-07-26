# ROLLBACK-001 result 10 — hostile content server

**Author:** Timur Isaev
**Date:** 26 July 2026
**Disposition:** Pass
**Repository base:** `458fb65987f8892598ffaa9269224c084a79de76`

## Exact claim

Transport treats the caller's descriptor size as an absolute streaming budget,
applies finite request and resource deadlines, validates response framing and
Range metadata, bounds redirects, and verifies SHA-256 before publication. Each
hostile response returns a stable named `ContentTransportError`. No refused
descriptor reaches `objects/`, and every refusal path is followed by a healthy
control fetch through the same store instance.

## Refusal matrix

| Hostile behavior | Required refusal |
| --- | --- |
| wrong bytes at the authorized size | `digestMismatch` |
| body closes before the authorized size | `truncatedBody` |
| body exceeds the authorized size without `Content-Length` | `responseTooLarge` |
| connection stalls after headers | `deadlineExceeded` |
| `Content-Length` disagrees with the authorized response length | `contentLengthMismatch` |
| redirects exceed the fixed budget | `redirectLimitExceeded` |
| redirect target contains user information | `invalidBaseURL` |

The oversized fixture supplies more bytes than authorized without a framing
length. The writer aborts on the first excess byte. Its quarantined `.part` is
exactly the authorized size and never larger, proving the budget is enforced
while streaming rather than after an unbounded download.

## Both-direction controls

`TransportHostileServerTests` creates one independent loopback fixture for each
row. Each test requires the exact error value, confirms the hostile descriptor
has no CAS path, stops that server, then fetches a distinct authorized payload
from a healthy fixture through the same `ContentStore`. The healthy object must
be byte-identical. This gives a success control after every added refusal,
including the deadline and redirect state machines.

The Range tests additionally accept the case-insensitive `Bytes` unit while the
parser rejects non-ASCII-decimal framing. Redirect targets are revalidated with
the same scheme, host, and user-information rules as configured mirrors.

## Recorded run

```text
Suite SerializedTransportTests passed
Test run with 16 tests in 1 suite passed
```

All fixtures bind to `127.0.0.1`; this gate makes no public-network request.
The full 34-case fault matrix, 4-case concurrency matrix, and 192-step stress
matrix also remained green.

## Reproduce

```sh
swift test --disable-sandbox --package-path runtime/content-store
runtime/content-store/run-fault-matrix.sh
runtime/content-store/run-concurrency-matrix.sh
runtime/content-store/run-stress-matrix.sh
```
