<!-- Author: Timur Isaev -->

# Synthetic Wine launch protocol

The Wine driver is explicitly enabled by a private endpoint's
`syntheticPayloadRoot` plus `fixtureMode: true`. The payload root must be canonical,
private and separate from the service's state/content roots. It is host-owned
development configuration, never a profile field or client-supplied host command.
The fixed sibling `alloy-session-agent` is digest-bound at service startup.
Ordinary profiles retain the existing refusal and cannot select either native
fixtures or this synthetic development path.

## Resolve and launch

`launch.synthetic.resolve` accepts `SyntheticResolveRequest`: source JSON as
Codable Data, the exact G: entry path, an idempotency key and a 1–120 second guest
watchdog. Source uses the profile compiler's
`alloy-synthetic-session-v1` contract, with `host`, `createdAt` and `volumes`
omitted. The service supplies actual host capabilities, the resolution timestamp
and its title-volume plan before invoking the compiler. Supplying those fields in
source rejects. The expected runtime generation/tree digest remains explicit.

Resolution binds the active generation and payload executable SHA identities,
creates private scratch and selects the cache by runtime, source and host identity.
It returns the existing `LaunchPreview` shape with a `wine-preview-` identifier,
120-second expiry and the complete canonical specification. Supported inputs have
`runtimeReady: true`, `productionEligible: false`. Unsupported policy requirements
stay visible; `launch.game` refuses their previews.

`launch.verify` recomputes the complete export and checks expiry, actual host and
active generation. `launch.game` accepts `{ "identifier": "wine-preview-..." }`.
It repeats verification, acquires a generation lease owned by the fixed agent's
exact PID/kernel start time, durably writes its request and only then releases the
agent's startup pipe. Expensive runtime verification and prefix initialization
happen in the agent; the XPC response returns a Wine session handle in STARTING.
Read `session.get` with its `wine-` session ID to observe progress/terminal status.
`session.stop` persists intent and closes the control pipe. `wine.session.list`
lists only Wine handles; the existing fixture list/model remain unchanged.

## Before guest execution

The agent verifies the actual materialized runtime against the content store and
requires the preview's generation and tree digest to match. It checks payload
bytes and executable PE machine headers against every bound image hash,
provider directories against the verified
tree, and the effective drive plan inside a live title-volume lease. It creates a
private prefix from the cached environment recipe and binds C's provider view to
the immutable runtime. The generation lease is checked again immediately before
execution.

Snapshot bytes are recompiled from the stored source. Their complete digest must
match before they are written privately; all writable handles close before a
read-only handle is opened and the file unlinked. `posix_spawn` explicitly maps
that handle to descriptor 198, with `ALLOY_POLICY_REQUIRED=1` and the expected
64-digit digest. Other descriptors close on exec. The existing v2 Wine hook
selects and verifies the policy before guest imports. Missing policy is never
retried as an unmanaged launch.

Named terminal codes include `RUNTIME_INTEGRITY`, `PAYLOAD_INTEGRITY`,
`POLICY_INTEGRITY`, `GENERATION_LEASE_MISSING`, `SESSION_WATCHDOG` and
`SESSION_CLEANUP_FAILED`. Refusal after STARTING appears in the session state and
correlated event history; it is not reported as successful guest execution.
Events bind the session, launch specification, generation and original request ID.
The fixed native fixture API remains separate and test-only.

`info.gameLaunchAvailable` is true only for an enabled Wine driver on a host the
compiler accepts. It advertises synthetic development capability, not certified
or production game support. Clients must distinguish Wine snapshots (`driver:
wine`) from the unchanged native fixture snapshots and honor terminal error codes.

Complete process inventory, health, staged stop and restart reconciliation are
specified in [Wine supervision](WINE_SUPERVISION_V1.md). The final provider/save
end-to-end proof is a separate milestone.
