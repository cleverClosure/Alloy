<!-- Author: Timur Isaev -->

# Alloy local runtime service

Issue #161 supplies the internal local-service foundation for the client and
live diagnostics. Milestone 1 implements a versioned XPC boundary and a reusable
Swift client. Milestone 2 connects the existing installation engine and durable
operation history, including reconnect and crash recovery. Fixture session
supervision follows in milestone 3. `info` reports game launch as unavailable.

```sh
swift test --package-path runtime/session-service
python3 runtime/session-service/run-boundary-proof.py
python3 runtime/session-service/run-boundary-proof.py --negative-control
python3 runtime/session-service/run-operation-proof.py
```

The ordinary proof must report `pass=9 fail=0 total=9`. The deliberately wrong
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
