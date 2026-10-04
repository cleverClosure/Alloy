<!-- Author: Timur Isaev -->

# Milestone 2: durable operations through XPC

The service adapts the unchanged catalog, installation engine and content store.
The new proof uses a private user launchd job, loopback HTTP bytes and the
committed two-game synthetic storefront library. Every CLI request is a new
client process, so the proof exercises reconnect rather than retaining local
object references.

Run `python3 runtime/session-service/run-operation-proof.py`. Its named rows
cover catalog pagination/details/discovery, fingerprinting, storage inventory,
queued/terminal idempotency, conflicting keys, pause without partial activation,
resume, exact install and repair bytes, durable event cursors, service restart,
cancel, uninstall and exact garbage collection. Storefront fixture hashes are
compared before and after. The operation count is eight: plans and rejected
conflicting requests must not create a ninth operation.

The matrix kills the actual service at each of four journal write boundaries
for QUEUED, STARTING and SUCCEEDED, plus the post-activation/pre-terminal boundary.
Each must fire its once marker, recover one operation and return the correct
result after restart. The client-death case kills a separate client after its
request is persisted but before the reply, then replays the same key.

`--negative-control` expects deliberately wrong installed bytes. Exactly that
row must fail while the same lifecycle and recovery rows otherwise pass. This
checks the independent payload oracle; it is not a physical power-loss proof.
Unit tests additionally reject adoption of unrelated content and a concurrent
service owner. Configured failure hooks are fixture-only and cannot be enabled
through a public RPC.

Final local outcome: four Swift tests pass; the live matrix reports
`pass=38 fail=0 total=38`; its wrong-byte control reports
`pass=37 fail=1 total=38`, failing only `verified-install-bytes`. All thirteen
service-kill markers and the killed-client gate were observed. An earlier
iteration expected nine operations and correctly failed that count assertion;
inspection confirmed eight created operations and one rejected conflicting
request, so the expected count was corrected before the final two runs.
The temporary fixture uses a one-second launchd throttle to keep deliberate
restart tests bounded without changing any installed service.
