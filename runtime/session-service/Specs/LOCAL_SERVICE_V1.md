<!-- Author: Timur Isaev -->

# Local runtime API v1

The Swift `AlloyRuntimeAPI` package owns the public request/response types and
`RuntimeClient`. XPC's exported Objective-C protocol exchanges `Data`; within it,
a versioned Codable envelope contains a method and a base64 Codable `Data`
payload. The typed client checks response version and request identity. The CLI
renders the payload as ordinary JSON for inspection. Calls block for at most
30 seconds and belong on a worker thread, never the client UI thread.

## Boundary

The current development service advertises a unique
`com.alloy.development.<random>` Mach service through a temporary user launchd
job. This follows Apple's
[NSXPCListener contract](https://developer.apple.com/documentation/foundation/nsxpclistener/init%28machservicename%3A%29).
A future app can use the same client contract while owning its service lifetime.
No global persistent service or root helper is installed by this package.

The listener checks the kernel-supplied effective UID and valid peer PID; it does
not trust a UID in a request. The router repeats the UID check and requires the
256-bit random capability from a 0600 regular, non-symlink endpoint file under
a 0700 owner-only directory. Requests carry that capability only over local XPC.
Configuration directories are owner-only, non-symlink final entries; filesystem
canonical paths prevent aliased or nested state/content roots. macOS's `/var`
and `/private/var` aliases are legitimate. Hostile concurrent filesystem
mutation and malicious same-UID code able to read the capability are outside
this development boundary; it is not a code-signing or sandbox authorization
claim. The proof uses a wrong capability from an actual peer; another UID is
covered by the router unit test without creating users or invoking sudo.

Application request/reply envelopes are capped at 4 MiB. This is checked before
JSON decoding and before reply publication, not a claim about kernel/XPC queue
allocation. Requests require API version 1, a nonempty ID at most 128 UTF-8 bytes
and a deadline within 30 seconds (one second forward-clock tolerance). Expired
requests, unknown methods, invalid JSON and unsupported versions fail with stable
codes. The client bounds its wait and checks identity; a timeout does not prove
that a future mutating method did not execute. Such methods must use durable
idempotency keys. Unknown envelope fields are ignored as optional v1 extensions;
new required semantics require a new supported version.

## Initial method

`info` takes `{}` and returns `ServiceInfo`: instance UUID, protocol version,
service PID/UID, supported methods and capability booleans. PID is informational;
it never authorizes a session or lease. Every restart creates a new instance UUID.
`developmentOnly` is true and `gameLaunchAvailable` is false.

Replies contain a stable code, message key, support code and retryable bit.
Boundary errors do not echo arbitrary input, paths, credentials or underlying
exception strings. Raw diagnostic capture must keep these same constraints.

The existing profile compiler's `runtimeReady == false` and `notYetLowered`
fields are authoritative. No milestone may silently reinterpret its development
export as a complete Wine policy or permit a real game launch from it.

## Durable operations (milestone 2)

Service configuration supplies at most 16 explicit read-only `libraryRoots`.
They cannot overlap the private state/content roots. A new mutable root must be
empty; a previously initialized root must carry this service's ownership marker.
The service refuses adoption of an unrelated directory and acquires an exclusive
process-lifetime state lock. These checks do not authorize hostile same-UID
filesystem changes. No root is inferred from Steam defaults or a remote request.

`AlloyRuntimeAPI/OperationAPI.swift` declares request and response records; the
existing catalog's public records remain the result authority:

| Method | Request | Result |
| --- | --- | --- |
| `catalog.list` | PageQuery | CatalogPage |
| `catalog.get` | IdentifierRequest (game ID) | GameDetails |
| `catalog.discover` | empty | GameInstallation array |
| `install.plan` | InstallPlanRequest | InstallPlan |
| `uninstall.plan` | UninstallPlanRequest | UninstallPlan |
| `install.start`, `uninstall.start` | KeyedIdentifier (plan ID, key) | CatalogOperation |
| `repair.start`, `fingerprint.start` | KeyedIdentifier (installation ID, key) | CatalogOperation |
| `inventory.start`, `gc.start`, `discovery.start` | KeyRequest | CatalogOperation |
| `operation.get` | IdentifierRequest | CatalogOperation |
| `operation.list` | empty | CatalogOperation array |
| `operation.run`, `operation.resume` | IdentifierRequest | accepted current CatalogOperation |
| `operation.pause`, `operation.cancel` | IdentifierRequest | durable CatalogOperation |
| `operation.updates` | OperationCursor | OperationUpdate |

Start calls durably enqueue and return an ID before execution. `run` schedules
work without blocking the XPC reply; success of this scheduling call is not
completion of the operation. The client polls `get` or `updates`. Explicit
resume is required for paused operations. A resume while a prior worker still
owns that operation returns CONFLICT; retry when `workerActive` becomes false.
Cancellation/pause follow the existing engine's cooperative publication rules.
Repeated run calls cannot enqueue concurrent workers for the same ID. On service
restart, queued/running/cancelling records are reconciled through the same
engine, while paused and terminal records remain unchanged.

The operation journal remains the sole authority for idempotency, stage history,
results and publication recovery. An operation error after uncertain publication
can remain RUNNING with `workerActive=false`; explicitly rerun that same ID.
No second journal or in-memory progress cache can override a durable outcome.
HTTP plans use existing digest verification, at most 64 layers (256 MiB per
layer) and four HTTP(S) mirrors, without URL user/password credentials. These
are internal-development bounds, not a supported production runtime-size claim.

## Subscription and reconnect contract

`OperationCursor(operationID, nextIndex)` resumes the durable event array at a
zero-based index. Each poll returns at most 128 indexed events and a new cursor;
`hasMore` indicates another page. A cursor beyond the current history is a
conflict, not an empty successful subscription. There is no volatile global
sequence to lose on service restart. Reusing a cursor replays the same events.

The complete snapshot is authoritative at its `revision` (event count); event
pages are an audit tail, not patches to apply over that newer snapshot. A client
must deduplicate event indices and ignore older snapshot revisions received
late. Requests may return identical snapshots, and a page can contain less
history than its snapshot. Follow `next` until `hasMore` is false, then continue
polling. The CLI starts a fresh client process for every proof request.

This is a pull subscription over XPC with no server-held callback. Local GUI and
diagnostic adapters can own cancellable polling tasks. The 4 MiB response bound
also applies to complete snapshots/lists: a large result fails explicitly,
rather than silently truncating. No production retention or unbounded-history
scalability claim is made. Credentials must not appear in event histories.

Test-only process death is configured out of band through an owner-only fixture
configuration (`fixtureMode`, `testFault`); no public RPC can enable it. A once
marker distinguishes an injected kill from an unobserved fault. The separate
reply gate pauses after persistence so the proof can kill the client before its
reply. Neither hook is activated by a profile or ordinary operation payload.

## Launch previews and fixture sessions (milestone 3)

| Method | Request | Result |
| --- | --- | --- |
| `host.info` | empty | HostCapabilities from the actual local host |
| `launch.resolve` | DevelopmentLaunchInput | LaunchPreview |
| `launch.verify` | IdentifierRequest (preview ID) | reverified LaunchPreview |
| `launch.game` | IdentifierRequest (preview ID) | always LAUNCH_NOT_RUNTIME_READY |
| `fixture.start` | FixtureStart | SessionSnapshot |
| `session.get`, `session.stop` | IdentifierRequest (session ID) | SessionSnapshot |
| `session.list` | empty | SessionSnapshot array |
| `fixture.kill-agent` | IdentifierRequest (session ID) | SessionSnapshot (fixture fault only) |

Preview creation and fixture execution require out-of-band `fixtureMode=true`.
A normal endpoint cannot turn either on through a request or profile. Resolution
uses the existing compiler's unsigned development mode: experimental profile,
development manifest/metadata and draft evidence. No release certification or
production trust is manufactured. The supplied documents/build/process/volume
identities are development inputs; this API does not independently attest them.
The service binds compilation to the actual host and a validated active content
reference, and retains the compiler's complete `notYetLowered` report. It requires
both `runtimeReady` and `productionEligible` to remain false.

A preview lasts 1–120 seconds. Its owner-only durable record preserves the input,
compilation time, host, generation reference, full specification and canonical
export. Verification recompiles at that frozen time, compares the full export,
checks current expiry/host and requires the same active generation. A modified
export, stale preview or changed generation cannot authorize a new fixture.
Existing sessions retain their acquired generation independently of later active
reference changes. There are at most 256 retained previews per development store;
this is a bounded development fixture, without an automatic retention policy.

Only the fixed sibling `alloy-session-fixture` executable can run. Its digest is
checked before launch and by each descendant. No RPC supplies a command, binary,
working directory or environment. A session ID is a digest of its idempotency key;
replay returns the same durable session and never relaunches it. Conflicting input
under that key is rejected. At most four owned trees run concurrently and 128
session records are retained. Each tree is exactly agent → child → grandchild.
Each process independently acquires the exact generation lease and records its
PID plus kernel start seconds/microseconds. Those identities, not a PID alone,
authorize signaling and determine liveness. Unknown kernel liveness retains the
lease and keeps the session conservatively live.

Control pipes provide cooperative stop and parent-death notification. Normal
stop closes the pipe. The termination-resistant fixture exercises TERM, a
one-second wait, exact-identity KILL, and a two-second exit wait. Every fixture
also has a 20-second hard watchdog; expiry exits 43 and reports FAILED, with an
EXITED_WATCHDOG node. Startup failure exits 42 without acquiring a lease. The
fixed fixture is cooperative code, not arbitrary-process containment or Wine
policy enforcement. The service does not invoke Wine or FEX.

Snapshots use RUNNING, STOPPING, STOPPED, SUCCEEDED, FAILED or INTERRUPTED. Poll
until a terminal state **and** an empty `liveNodes` array; an agent's exit alone
is not proof that descendants exited. Node records retain the exact lease
identity as historical evidence after release. A service crash closes the root
control pipe; descendants exit and the new service reconciles durable records
against kernel identities. Without a durably observed exit result it reports
INTERRUPTED rather than inventing success. Stop intent and observed exit codes
are durable. Sessions are never automatically restarted. Content-store GC
remains the authority for stale lease reconciliation and must protect every
live fixture generation even after uninstall removes its active reference.
