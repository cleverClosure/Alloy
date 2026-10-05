<!-- Author: Timur Isaev -->

# Local diagnostics integration v1

This adapter consumes the versioned development XPC API. It imports public
result models and never the service implementation. Runtime packages, the app,
shared Wine/FEX trees and decision records remain unchanged.

## Identity and provenance

Every structured event uses the existing offline v1 envelope. Its mandatory
slots cannot encode absence. The reserved value `unavailable` (including the
single provider-map entry `unavailable: unavailable`) is therefore an absence
marker, **never a provider, digest, request, policy or certification identity**.
Each event declares this convention, local development provenance, and missing
provider/process-policy evidence. Consumers must not treat markers as coverage.

The request ID is the service's verified reply ID for the diagnostic read. The
original mutation RPC ID is not retained by the service and is explicitly
unavailable. Idempotency keys are private input, not request IDs. Operation IDs
and ordered state/stage history come from the actual journal. Install/repair
plans supply game and runtime generation; absent build/session/profile fields
remain unavailable. Snapshot payloads/results, credentials and endpoint files
are never copied wholesale into diagnostics.

Session ID, game, build, local host class, generation and profile/revision come
from the retained session preview. Its canonical export must agree with its
typed specification, generation and every node's acquired lease. The native
fixture digest and owned node PID/start-time tuples are separately classified.
Declared component digests remain declarations, not evidence of loaded
providers. Unsigned development previews do not supply production certification.
The fixture's process-policy declarations are not the native fixture's policy.

## Ordering and completeness

An operation snapshot is authoritative; its audit tail must exactly match the
requested contiguous indices and the full snapshot history. Missing, reordered,
changed or excessive history is refused. Duplicate observations are ignored;
older snapshots are ignored only after their common history matches. Terminal
records cannot change. A full history snapshot can honestly cover a paginated
tail; at most 512 events are accepted. The service currently caps its own data.
Session snapshots have no event sequence: `historyComplete` is false, even for
a clean session. They are not an atomic transaction with operation observations.

The client checks service instance before and after observation. Disconnect,
restart during a read, malformed data and unknown fields are errors, never
successful empty observations. Reconnecting starts a new observation with the
new instance ID and the same durable target identity. Request waits are 5s each
(three calls per observation); wire data is capped at 4 MiB. Unknown wire fields
are refused pending explicit classification rather than silently discarded or
exported. Scalar unknown state values likewise require a contract update.

Existing redaction rejects secret-like metadata and removes supported secret
patterns from classified fields. Its documented grammar and limitations still
apply. Exact identities that contain supported secrets fail closed; they are
never silently changed into a different identity.

## Observed failure capture

`capture ENDPOINT operation|session ID terminal|hang SECONDS` observes a target
within a 0.1–35s monotonic budget. Each RPC gets only the remaining allowance,
up to 5s; the native sampler uses 2–5s of the same budget and up to 0.5s additional
tool cleanup. Host scheduling/syscall latency can add overhead; these are checked
software budgets, not hard real-time guarantees. Caller deadlines should include
that cleanup allowance. Ending observation does not cancel the service's work.

A failed operation requires a real FAILED snapshot. The native abort case uses
a service-recorded exit status 6, a fixed native fixture, and the proof's exact
PID/start-time/executable-digest checked SIGABRT injection. It records native
exit evidence, **not a symbolicated crash stack or an arbitrary-crash classifier**.
A hang requires an actual macOS sample at `FixtureMain.run:poll` in an owned
agent, followed by the fixture's existing 20s watchdog exit 43 and no live nodes.
The sample primitive rechecks kernel start time before and after sampling and
never signals the borrowed process. The runtime service retains process ownership.

Capture reports `complete: false` for budget exhaustion, interruption or missing
native evidence. Session history remains snapshot-only independently of capture
completeness. An instance change between RPCs or after reconnect cannot be called
a clean capture. The test pairs failed work with a successful operation and a
normally exiting native fixture. It uses no Wine guest or real user content.

The sampler's raw output is in private scratch (0700 directory/0600 file), at
most 1 MiB of accepted data, removed on every return. Only a typed site/ownership
summary survives; the raw module/path inventory is excluded. The sample tool's
temporary disk output is checked after execution, not a physical disk quota.
The proof stops/reaps all service-owned nodes before removing temporary stores.

A narrow redactor extension recognizes a canonical UUID only in `request_id`:
random protocol UUID digits must not be mistaken for a payment-card number.
Free-text values and non-UUID identities still use the complete secret scanner.
