<!-- Author: Timur Isaev -->

# Alloy local runtime service

Issue #161 supplies the internal local-service foundation for the client and
live diagnostics. Run the complete handoff in one command:

```sh
python3 runtime/session-service/run-integration-proof.py
```

The [consumer handoff](Specs/CLIENT_HANDOFF.md) covers the public Swift API,
reconnect contract and reusable native fixture for #162 and #163.

Milestone 1 implements a versioned XPC boundary and a reusable
Swift client. Milestone 2 connects the existing installation engine and durable
operation history, including reconnect and crash recovery. Milestone 3 adds
compiler-verified development previews and fixed native fixture supervision.
The baseline endpoint reports game launch as unavailable; the opt-in synthetic
Wine driver below has a separate readiness contract.

```sh
swift test --package-path runtime/session-service
python3 runtime/session-service/run-boundary-proof.py
python3 runtime/session-service/run-boundary-proof.py --negative-control
python3 runtime/session-service/run-operation-proof.py
python3 runtime/session-service/run-session-proof.py
```

The boundary proof must report `pass=9 fail=0 total=9`. The deliberately wrong
authorization oracle reports `pass=8 fail=1 total=9` and exits 1. The proof loads
a uniquely named current-user launchd job from a private temporary plist, makes
calls from a separate client process, and removes the job and files afterward.
It neither installs a persistent LaunchAgent nor needs a signing account or root.

The service and client use an explicitly supplied owner-only endpoint file and
separate private state/content directories. `proof_support.py` is the reusable
development launcher. The endpoint file is a local capability and must never be
committed or included in diagnostic exports.

[LOCAL_SERVICE_V1.md](Specs/LOCAL_SERVICE_V1.md) specifies the transport and
security scope. [Milestone 1 evidence](Results/2026-10-04-boundary.md) records
controls and reproduction. Both the Swift suite and actual XPC proof are
registered in the existing `tools/test-all` fast tier.

The [operation proof](Results/2026-10-04-operations.md) exercises the actual local
service, catalog and content store, including thirteen service-kill boundaries
and client death before a persisted request's reply. It is also registered in
the existing fast tier. `OperationCursor` supplies a pull subscription that can
resume across process and connection restarts.

The [session proof](Results/2026-10-04-sessions.md) preserves incomplete compiler
exports, refuses real game launch and exercises bounded native process trees,
exact-generation leases, stop escalation, death and restart reconciliation.
It is registered in the fast tier and requires no x64 guest.

The full session proof requires an actual arm64 Mac with at least 8 GiB, matching
the unchanged launch compiler. The test runner reports a named SKIP otherwise;
`run-launch-host-proof.py` still runs and verifies truthful host identity and
refusal. Hosted machines below that minimum do not receive session coverage
credit. Local full-proof results remain separate from hosted refusal evidence.

## Wine session environment

The [session environment contract](Specs/SESSION_ENVIRONMENT_V1.md) adds cached,
reproducible prefixes, title-volume mappings and private Wine servers for #181.
The [Wine launch protocol](Specs/WINE_LAUNCH_V1.md) enables verified synthetic
x64 launches under inherited v2 policy. Its [proof](Results/2026-10-06-wine-launch.md)
uses a separate XPC client and tests corrupt snapshots and missing leases.
Ordinary profile launches remain gated. [Wine supervision](Specs/WINE_SUPERVISION_V1.md)
adds complete child inventory, unknown-child reporting, generation lease health,
staged stop, watchdog and crash reconciliation. The full-tier
`runtime-service-wine-tree` suite exercises real nested Windows guests and
retains short-lived children in its inventory.
