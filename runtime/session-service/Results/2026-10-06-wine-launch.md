<!-- Author: Timur Isaev -->

# Service-driven x64 policy launch

Milestone 2 of #181, 6 October 2026. The registered
`runtime-service-wine-launch` full-tier suite passes against the completed #177
package imported into a fresh service-owned content store. The
[recorded result](2026-10-06-wine-launch.json) contains the exact runtime identity,
guest digest, mapped builtin FEX paths and correlated session events.

| Session | Result |
| --- | --- |
| Valid x64 guest | SUCCEEDED, entry marker observed, exact generation FEX mapped |
| Changed snapshot bytes | POLICY_INTEGRITY, no guest entry |
| Released generation lease | GENERATION_LEASE_MISSING, no guest entry |
| Fresh valid session after both faults | SUCCEEDED, exact generation FEX mapped |

All calls use the separately launched `alloy-runtime-client` through authenticated
XPC. Both positive sessions execute `guest-smoke.c`, which prints its known marker
and returns success only if the complete write succeeds. Runtime verification
after all four sessions matches the imported generation byte inventory. The
runtime tree digest is
`sha256:6fbeb915a7bb987b060d14ef6060a510ce9632a817c123799547d4bae9fd6610`.

Eleven package tests pass, including a real child that reads the explicitly inherited
descriptor and controls proving read-only access, unlinking and digest refusal.
PE header checks also reject a native executable, a wrong machine and a DLL.
All five focused service suites pass: Swift, XPC boundary, native fixture sessions,
actual-host refusal and client integration. The baseline incomplete-profile gate
and native fixture behavior remain intact. Repository lint and registry
self-tests pass.

The first fixture setup refused an unowned imported root; the proof now initializes
empty roots through the service before import. The first successful guest run
lacked the `module` trace channel and failed the FEX-path oracle; enabling the
actual builtin-image instrumentation makes that independent assertion pass.
The launchd cleanup check now allows a bounded three-second removal interval,
instead of declaring a still-tearing-down registration to be a permanent survivor.

This milestone proves policy delivery and lease/file gates for one x64 guest.
Complete child inventory, staged termination, restart recovery, distinct provider
markers and save/rollback evidence remain assigned to milestones 3 and 4.
