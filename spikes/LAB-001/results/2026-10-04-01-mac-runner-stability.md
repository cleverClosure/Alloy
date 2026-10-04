<!-- Author: Timur Isaev -->

# LAB-001 Mac synthetic runner: consecutive stability proof

## Identity and conditions

Tested source commit: `d6fa9d3846f85a30a365570467905a2d1ef49595`, the pushed
milestone-five branch. Every captured record reports that commit and a clean
source tree. Closing changes add this report, SPIKE.md and the evidence dataset;
they do not change any tested Python source or scenario.

Host: arm64, 12 logical CPUs, 17,179,869,184 bytes physical memory, Darwin 27.0.0
kernel build `xnu-13432.1.9~1/RELEASE_ARM64_T6020`. The full OS version and Python
identity are in every record. Before measurement, process inspection found no
shared or isolated Wine run; the concurrent catalog task held local builds and
tests for the short calibration/acceptance window. No power/thermal or real-game
performance claim is made.

| Selected input | SHA-256 |
| --- | --- |
| Native Python executable | `4f00ea2ad53d62437a6a3946b73c73614a97e8accdc5b96dc095ea1a0d9c6a56` |
| Runner | `dce1a1639543ae23f67416b65448162a50af2e9c095d8e19c35eb4ca1cb6e6ca` |
| Scenario validator | `f91bcd9af400cec41efbcffbcc675ad347c108abcf5022c15553b3669f40a7da` |
| Subject | `9127ff2a9987b2baa26ae6f3c1c1b70df19df3f5e0f4b320cdd4d21714961f18` |

## Executed proof

The [SPIKE reproduction commands](../SPIKE.md#reproduce) ran with bytecode writes
disabled, first using `work/acceptance-calibration` (eight clean processes), then
`work/acceptance-a` and `work/acceptance-b` (five clean plus one seeded process
each). The commands completed consecutively without changing source or scenario.
The final two commands both used calibration
`f5c8436b01697f59d6205578bbf9ff068c64dfadf47b546a57fa8db37a2b3b3d`.
All 20 run IDs are distinct; the calibration sample IDs/digests are retained.

| Observation | Acceptance A | Acceptance B |
| --- | ---: | ---: |
| Clean comparisons | 4 CLEAN | 4 CLEAN |
| Real seed | REGRESSION | REGRESSION |
| Comparator self-tests | 6/6 | 6/6 |
| Variance violations | 0 | 0 |
| Lifecycle wall mean | 0.050974s | 0.051149s |
| Lifecycle wall range | 0.005625s | 0.007748s |
| Reaped child CPU mean | 0.046159s | 0.046142s |
| Reaped child CPU range | 0.003782s | 0.004131s |
| Full function wall cost | 0.511813s | 0.509195s |
| Shell `time -p` real cost | 0.59s | 0.59s |

All deterministic-counter variances are zero. The seeded image differs from the
clean image only at frame 0 byte offset 13, changing 0 to 1; its channel sum is
344,065 instead of 344,064. The comparator reports actual frame/counter changes,
not a verdict inferred from the mode label.

`check_variance.py` independently recomputed all ten metrics for the calibration
batch and both full batches and passed. Unit verification passed 19 tests,
including actual hang/nonzero/flood/descendant controls, evidence corruption,
reused calibration samples, malformed/resealed statistics, known slowdown, wrong
reported mean and three deliberately broken classifier behaviors. Earlier
milestone review independently checked calibration/holdout artifact inventories
and the one-byte seeded difference before the committed-source repetition.

The difference between full-function and shell cost includes interpreter startup,
final JSON serialization/output and shell timer rounding. Child CPU is measured
separately and is not substituted for wall-clock cost.

## Retention and limits

The [committed JSON](2026-10-04-stability-evidence.json) has SHA-256
`4334da2a516ca0284ac07d4356d5327a71ac4baed0181189d69f23e80b5da9c1`.
It preserves all 20 complete evidence records and raw measurements, calibration
and both full reports. Actual bound files remain in the ignored local work
directories, including every PPM, log, raw JSON and selected-source archive.
Hashes and local records provide reproducibility and accidental-edit detection,
not an authenticated signature or independent execution attestation.

Result: issue #77's Mac synthetic slice passes. #15/Windows, real-title binding,
Wine execution, certification thresholds and the complete doc 16 D3D11/Windows
prototype remain follow-ons. No shared runtime, docs package or hosted-CI
configuration changed.
