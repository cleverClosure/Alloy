<!-- Author: Timur Isaev -->

# Performance baseline and controls — 4 October 2026

The final baseline was recorded in a coordinated quiet window in 36.277 seconds.
The committed rerun used the same fixture identities and reproduced every median
within its fixed limit in 39.802 seconds. Both runs collected 30 samples across
10 cases. A previous successful rerun overlapped a brief Git unit test, so it was
repeated; only the uncontended rerun is committed.

| Case | Baseline median (s) | Clean rerun (s) | Fixed limit (s) |
| --- | --- | --- | --- |
| catalog-10 | 0.006775 | 0.006630 | 0.106775 |
| catalog-100 | 0.014498 | 0.013146 | 0.114498 |
| catalog-1000 | 0.052685 | 0.053014 | 0.263424 |
| gc-10 | 0.012737 | 0.012332 | 0.112737 |
| gc-100 | 0.094884 | 0.096526 | 0.474420 |
| scan-100 | 0.031062 | 0.030701 | 0.155312 |
| scan-1000 | 0.258590 | 0.256231 | 1.292952 |
| scan-20000 | 4.758820 | 4.872643 | 23.794102 |
| transport-fresh | 0.009146 | 0.008952 | 0.109146 |
| transport-resume | 0.007309 | 0.007186 | 0.107309 |

The real delayed GC control measured **0.250722s**, exceeding
its **0.112737s** limit. The gate first reported that named
failure, required it, and then accepted every clean case. This uses the same
comparison function as ordinary measurements; no fake result row is substituted.

The cancellation control creates a real ten-generation store, hangs the actual
Swift performance test while recording its PID/heartbeat, and cancels the top
Python owner through the registered test-all supervisor. The test process must
stop and its parent-owned store directory must disappear. This control passed.

See [measurement boundaries and threshold](../PERFORMANCE.md),
[raw baseline](performance-baseline-v1.json), and
[raw clean reproduction](2026-10-04-performance-rerun.json).

Hosted validation resumed after the repository became public. The complete
implementation passed all **30 fast suites**, with no failures or skips, in
**474 seconds** on the public macOS runner. The run includes all 86 content-store
tests and all 34 identity tests, real ENOSPC and disabled controls, parser
mutation and timeout controls, the 21,100-file identity pipeline, and performance
threshold checks including rejection of the deliberately delayed GC operation.

| Hosted observation | Wall time | Result |
| --- | --- | --- |
| [Milestone 1](https://github.com/cleverClosure/Alloy/actions/runs/37187847507) | 211s | 25 suites passed |
| [Milestone 2](https://github.com/cleverClosure/Alloy/actions/runs/37200147883) | 325s | 26 suites passed |
| [Milestone 3](https://github.com/cleverClosure/Alloy/actions/runs/37200723864) | 314s | 27 suites passed |
| [Milestone 4](https://github.com/cleverClosure/Alloy/actions/runs/37201179099) | 446s | 28 suites passed |
| [Full implementation, assertions inverted](https://github.com/cleverClosure/Alloy/actions/runs/37200217212) | 448s | 28 passed; exactly two intended failures |
| [Full implementation, assertions restored](https://github.com/cleverClosure/Alloy/actions/runs/37200823968) | 474s | All 30 suites passed |

Every run is below the existing **900-second** job budget. The failing control
inverted the empty-content digest assertion and the Unicode-path aggregate
assertion. The passing run differs by exactly those two operators restored from
`!=` to `==`. Rebasing onto the merged prerequisites did not change its source
tree. The final milestone's complete implementation matches that successful
tree byte for byte before these evidence files are added.

The disposable [control PR #156](https://github.com/cleverClosure/Alloy/pull/156)
was closed **unmerged** and its branch deleted both remotely and locally.
[Structured hosted evidence](2026-10-04-hosted-proof.json) preserves the commit
and tree IDs, exact restoration diff, log hashes, suite results, and timestamps.
The final milestone [PR #152](https://github.com/cleverClosure/Alloy/pull/152)
also requires its own green CI run before merging; its final wall time is
recorded on that PR.

Initial hosted attempts exposed APFS detach taking longer than the old
four-second attempt limit. The repaired bounded cleanup passed both cancellation
paths and all ten pressure/control cases; one successful hosted detach measured
10.517 seconds. Those initial failures are retained as diagnostic evidence,
separate from the accepted two-assertion control pair.

The final local CI-equivalent engine self-test and all **30 fast suites** passed
in **316.362 seconds** (5m16s), below the existing 900-second job budget. This
includes 86 content-store tests, 34 identity tests, the promoted stress matrix,
and all four newly registered hardening gates. The two deliberately inverted
assertions each failed with exactly the intended single failure before source
restoration and this green run. See the [structured full-gate result](2026-10-04-local-fast-gate.json)
for source-file hashes, exact suite verdicts and local timing, and the
[local assertion controls](2026-10-04-local-assertion-controls.json). The hosted
observations above complete the required CI evidence independently of these
local results.
