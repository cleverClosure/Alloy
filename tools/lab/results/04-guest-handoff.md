# Milestone 4: real x64 guest and consumer handoff

Author: Timur Isaev

On 2026-10-06 the final [guest proof](04-guest-proof.json) ran five actual scheduled
jobs against an isolated copy of the verified #176 development runtime. The
content-store materializer first verified generation
`rtg_2f08b16b119993b38747f8565d732fdb429313341b0a0731e31578f48a8c6252`,
manifest `fcf5406df067376fb650ae3b74754c253ffe3db8999a6f0bda44ad3f95793b52`
and tree `dcc1caa40973f1614742a0b2dff486fef5ba24b7fd7073a76aaed7ed6292c4a5`.
Its three provider aliases were materialized as regular files in the private copy.
The lab identified all 835 files by the distinct canonical inventory digest
`903e09091ef16d73e018b5eb380b975e4c26cd45d035a4a6c4f33de31d4bc7ae`.
No shared Wine/FEX source or build artifact was changed.

| Control | Actual outcome |
| --- | --- |
| Calibration | UNBASELINED; answer 42, sum 21; explicit baseline frozen |
| Fresh clean holdout | CLEAN; answer 42, sum 21 |
| Seeded guest | REGRESSION; answer 43, sum 22; both observables named |
| Wrong expected runtime digest | INCOMPARABLE; no steps executed |
| Hanging guest | FAILED with RUN_TIMEOUT; private server stopped and waited |

Every completed x64 run's captured Wine trace names the isolated runtime's exact
`libarm64ecfex.dll` image. The guest has a construction-known answer and independently
changed outputs; the comparison does not infer its verdict from a control label.
Both failed and completed attempts retain records and raw logs. Teardown outcomes,
post-run process inventory and an available exclusive lab lease establish cleanup.
The runtime inventory is unchanged after the proof. Raw evidence remains in
`/private/tmp/alloy-180-final-guest-fixed/queue/` under the recorded content addresses.

Initial guest integration correctly failed when the stop-server step returned 1
after the server had already exited. The adapter now explicitly permits Wine's
0/1 stop outcomes and still requires bounded successful wait and process cleanup.
The generic schema accepts a single expected exit or a bounded unique set; actual
statuses remain validated and visible. Wine trace capture has a bounded 1 MiB
allowance per stream, while native scenarios retain 64 KiB. Complete Wine inventory
checks reject additional files and links as well as changed/missing files.

The registered full `lab-wine-guest` proof passed in 74.4 seconds; the final direct
proof also passed after preparation acquired the same host lease. Fast coverage
comprises 28 tests across four registered lab suites. Wine-boundary controls need
no installed Wine; the real full suite requires explicit verified runtime and
toolchain inputs and otherwise reports SKIP. Repository lint and test-all's own
supervision/registration self-tests pass.

The first complete fast-tier attempt passed 49/50 suites. The pre-existing
`content-store-disk-pressure` identity-scan case unexpectedly fit a write on its
private APFS image after the filler observed ENOSPC. The unchanged isolated suite
then passed all five injected failures and all five disabled controls. Its first
failure remains in `/private/tmp/alloy-180-final-fast.json`; the independent rerun
is `/private/tmp/alloy-180-disk-pressure-recheck.json`. No assertion was weakened.

The second full attempt passed disk pressure but exposed a concurrent database
initialization race in the lab shared-worker test (`database is locked`). The
final milestone serializes only SQLite setup with a bounded, kernel-owned file
lease; normal WAL transactions and guest execution remain concurrent. A new
independent flock control proves open is blocked until release, and eight fresh
processes open each database concurrently. The original failing run remains in
`/private/tmp/alloy-180-final-fast-recheck.json`. The complete post-fix gate writes
`/private/tmp/alloy-180-final-fast-fixed.json`; hosted CI independently runs the
same registered fast tier before the final merge.

[HANDOFF.md](../schemas/HANDOFF.md) documents submission, explicit baseline freezing,
worst-history gating, cancellation/deadlines, Wine prefix ownership, exclusive
performance work and the CLI for other agents' heavy work. These results cover
local engineering controls, not real game certification, graphics, signing,
Windows reference execution or production release.
