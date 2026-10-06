<!-- Author: Timur Isaev -->

# Client and live-diagnostics handoff (API v1)

This package supplies the local-service dependency for #162 and #163. The
[wire, operation and session contract](LOCAL_SERVICE_V1.md) is authoritative.
Neither consumer needs to modify the service implementation or access a shared
Wine/FEX runtime to exercise the service.

## One-command integration

From the repository root on Apple Silicon macOS with the repository's Swift
6.2 toolchain and at least 8 GiB of actual host memory:

```sh
python3 runtime/session-service/run-integration-proof.py
```

This builds the Swift package, creates a private temporary user launchd job,
discovers the committed `steam-910001` synthetic title (build 21), installs exact
loopback bytes, resolves its preview, runs/stops a three-process fixture, kills
and reconnects to the service, replays operation/session identities and reclaims
the exact object after uninstall. The title's real fixture fingerprint supplies
the preview's build ID, manifest ID and file digests. Process-policy observations
remain synthetic; the storefront fixture contains text, not a game executable.
A changed export must fail verification before the clean export is accepted.
All temporary launchd registrations and files are removed before success.

`--negative-control` deliberately expects the corrupted export to verify. It
must exit 1 with only `broken-export-detected-before-clean-control` failing.
This is an independent wrong oracle paired with an actual modified durable
export, not a new service bypass. No command contacts an external mirror, needs
a game account or launches Wine/FEX.

## Swift consumer

Add a local Swift package dependency on `runtime/session-service`, then depend
on the `AlloyRuntimeAPI` product. Import the existing result-model modules
`AlloyStoreCatalog`, `AlloyContentStore` and `AlloyProfileCompiler` where explicit
type names are needed. The CLI target is a compiled consumer example: it imports
the API and result models, never `AlloyRuntimeService`.

```swift
import AlloyRuntimeAPI

let configuration = try ServiceConfiguration.read(endpointPath)
let client = RuntimeClient(configuration: configuration)
let cursor = OperationCursor(operationID: operationID)
let update = try await Task.detached {
    try client.updates(cursor)
}.value
```

The app owns cancellable polling tasks and calls off its UI thread. Each call
uses a new bounded XPC connection. Cancelling a polling task stops observing;
it does not cancel an operation or session. A timed-out mutation has an unknown
outcome: reconnect using the same durable idempotency key or operation/session
ID. Never automatically retry with a new key.

Convenience methods cover info/host/catalog, install planning/start,
operation control/snapshots/updates, launch resolution/verification and fixture
start/session snapshots/stop. `request(_:_:returning:)` covers every remaining
method using its public Codable request type and the documented result type.
`DevelopmentLaunchInput` has a public initializer. `RuntimeFailure.status`
retains stable errors; `RuntimeStatus(code)` gives the message and support keys.
A transport failure is distinct from a service rejection and from a durable
operation's FAILED state.

Persist operation IDs and `OperationCursor.nextIndex`. Render the latest complete
snapshot, deduplicate event indices, and ignore snapshots older than the last
rendered revision. Session snapshots are polled separately and are not atomic
with operation/catalog reads. Wait for a terminal session state plus an empty
`liveNodes` array. Display INTERRUPTED honestly; replaying its original fixture
start returns that same interrupted session, without launching another tree.

On the baseline fixture endpoint, `info.gameLaunchAvailable` is false. Show preview coverage and unavailable launch
capability. Never hide `notYetLowered`, change readiness flags or offer the native
fixture driver as a real game's execution provider. Preview input is local
unsigned development evidence; no production certification or storefront trust
is implied. Expired previews need a fresh resolution; an existing session keeps
its acquired lease even if its preview later expires.

## Reusable fixture and inspection

`proof_support.ServiceFixture` and `launch_fixture.launch_input` are committed
Python fixture entry points. Add `runtime/session-service` to `sys.path` in a
consumer's bounded test. `build()` locates the package executables.

```python
from proof_support import PACKAGE, ServiceFixture, build

library = PACKAGE.parent / "store-catalog/Tests/Fixtures/MultiGameLibrary"
with ServiceFixture(build(), libraries=[library]) as fixture:
    endpoint = fixture.endpoint  # pass this private path to the client under test
    info = fixture.request("info")
    fixture.restart()           # actual service death and restart
```

Keep the context alive while the consumer runs and give the consumer process an
explicit timeout. The integration proof demonstrates runtime installation and
`launch_input(..., discovered=installation)` before `fixture.start`. No source
patch or shared runtime setup is required. Scenarios are normal, startupFailure,
hang and ignoreTermination. Use `session.stop` for normal control and
`fixture.kill-agent` for the explicit native-agent death control. Every fixture
has its own 20-second watchdog, including an unattended hang. A missing cleanup
acknowledgement is a failed test, never a pass or a skip.

The separate `alloy-runtime-client` executable accepts the endpoint path followed
by a wire method and optional `--stdin` JSON. Its ordinary output includes code,
support code and payload; exit 2 means service refusal and exit 1 means local or
transport failure. Four development inspection commands instead emit their typed
result directly: `typed-preview`, `typed-fixture-start`, `typed-session-stop` and
`typed-snapshot`. They consume JSON on stdin. The last accepts
`{cursor: OperationCursor, sessionID: string, previewID: string}` and makes
separate typed calls for info, catalog, updates, preview verification and session.
It is a diagnostic composite, not a transactional server method.

Use `fixture_mode=False` to verify normal endpoint refusal. Test-only faults
cannot be enabled via a request. Credentials, endpoint files, preview documents,
local paths and full launch exports are private inputs, not safe diagnostic
attachments. #163 must apply its existing redaction/export rules when adapting
these live records. Do not send a capability or unreviewed raw record to logs,
telemetry, reports or issue attachments.

## Bounds and handoff limits

The service is current-user development infrastructure, with no persistent
LaunchAgent installation, root helper, signing identity or third-party dependency.
Existing catalog/content-store/compiler packages remain unchanged. API messages
are 4 MiB maximum and client waits at most 30 seconds; previews expire within
120 seconds. Development-store retention caps and process budgets are specified
in the wire contract. Pull subscriptions have no callback lifetime to recover.
The fixed fixture proves local ownership, recovery and lease behavior. The
explicit [synthetic Wine contract](WINE_LAUNCH_V1.md) adds a separate Wine session
model and enabled capability; clients must opt into that development contract.
The [Wine supervision contract](WINE_SUPERVISION_V1.md) defines complete process
records, health, stop and recovery. Production launch remains separate work.

## Synthetic Windows sessions

The [complete Windows session handoff](SESSION_E2E_V1.md) and its
[execution record](../Results/2026-10-06-session-e2e.md) cover #181. A private
endpoint must have both `fixtureMode: true` and a configured
`syntheticPayloadRoot`. `info.gameLaunchAvailable` then advertises this explicit
development driver only on a supported actual host. A normal endpoint continues
to refuse unsupported production launches; its native fixture is not a fallback.

Use `RuntimeClient.request(_:_:returning:)` for this model:

| Wire method | Request | Result |
| --- | --- | --- |
| `launch.synthetic.resolve` | `SyntheticResolveRequest` | `LaunchPreview` |
| `launch.verify` | `IdentifierRequest` with `wine-preview-...` | `LaunchPreview` |
| `launch.game` | `IdentifierRequest` with the verified preview ID | `WineSessionSnapshot` |
| `session.get`, `session.stop` | `IdentifierRequest` with `wine-...` | `WineSessionSnapshot` |
| `wine.session.list` | Empty JSON object | Array of `WineSessionSnapshot` |

The request source is JSON encoded as Codable `Data` (base64 in the JSON wire
request). Omit `host`, `createdAt` and `volumes`: the service binds these fields.
Provide the immutable generation/tree identities, exact G: entry path, known PE
image hashes, per-process policies and an explicit restricted default. A ready
synthetic preview remains `productionEligible: false`. Never replace omitted
production controls with a synthetic policy to make an ordinary title launch.

Decode `driver: "wine"` as `WineSessionSnapshot`; the native fixture's convenience
methods and `typed-snapshot` command use a different model. Launch admission
promptly returns STARTING after persisting a pending record for a helper held on
its startup gate. Expensive content validation and lease acquisition continue
off the XPC request path. The helper cannot proceed until the fully verified
generation lease matches its captured birth identity and the complete request is
durable. The agent then verifies runtime/payload/policy and prepares its prefix.
STARTING acknowledges admission, not guest execution or successful validation.

Pending STARTING and STOPPING snapshots have an empty event array; clients must
not require or synthesize nonterminal admission events. The agent's later event
stream, or a terminal admission failure, supplies the correlated history.
A later FAILED snapshot may carry `RUNTIME_INTEGRITY`, `PAYLOAD_INTEGRITY`, `POLICY_INTEGRITY` or
`GENERATION_LEASE_MISSING` before any guest executes. Handle `SESSION_WATCHDOG`,
`SESSION_INTERRUPTED`, `PROCESS_INVENTORY_INCOMPLETE` and `SESSION_CLEANUP_FAILED`
explicitly. A stop response acknowledges intent, not completed process cleanup.

Poll the durable session ID through a terminal snapshot. Retained process rows
should all have `exited: true` after successful cleanup; `processes` is historical
inventory and does not become empty. Render `identifier` and `parentIdentifier`
as identity and parentage. Wine/Unix PIDs alone are not stable identities; a
short-lived process can legitimately lack an observed native birth record.
Show `unknown` classification and its default policy ID. That policy ID records
the expected selection; the proof's DLL-attach observations independently check
what the process received before imports.

After a transport timeout, use the durable ID or `wine.session.list` to find the
existing session; do not start a replacement with a fresh key. A still-valid
preview can replay its existing launch. Preview expiry or changed active
generation can reject later verification without undoing an already acquired
session lease. Service restart requests existing sessions to stop and reconcile;
it never promises to resume guest execution automatically.

Wine events carry `sessionID`, `launchSpecID`, `generationID` and the original
launch request's `correlationID`. Deduplicate by sequence within a session; the
bounded recent-event ring can begin above sequence one. These events are separate
from `OperationCursor`. Keep the complete correlation tuple when producing
reviewed diagnostics. The proof's optional local capture includes private
`pending.json`, `request.json`, `bootstrap.json`, state/ownership records and
Wine/server logs when present. It scans these bytes for the endpoint credential
and never copies the endpoint file. That check does not make full launch inputs,
host paths or other raw records safe to share. Keep this capture private; use
the existing #163 review, redaction and export rules to create a separate
publishable bundle. Never publish the endpoint capability or unreviewed raw
admission/request records.

Runtime activation and rollback choose immutable files. They must not restore,
replace or recreate the title's S: save volume. The proof checks saved bytes after
stop, service death, refusals and both A → B and B → A activation. Its drive
namespace and provider marker DLLs do not establish host filesystem isolation,
network confinement, graphics compatibility or production eligibility.

The existing compiler requires at least 8 GiB to produce a local host identity.
The [standard hosted arm64 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
reports 7 GiB, also confirmed by the actual hosted compiler-test log. The full session and integration
suites therefore have an explicit measured hardware prerequisite and report
SKIP on that runner. The separate `runtime-service-launch-host` suite always
checks truthful host memory, compiler refusal and absence of side effects; the
boundary, operation and Swift suites also still run. Full local process proofs
and hosted refusal coverage are separate results. Neither consumer may inflate
host capabilities to make a preview compile on unsupported hardware.
