# CPU-001 result 30 — retire CAS-tear clean-run claims, calibrate the narrower census

Author: Timur Isaev

Issue #78 takes its retirement outcome. The 16/32/64/128-bit CAS-tear flags are
permanently excluded from clean-run eligibility for this census unless a future
change supplies a deterministic guest positive control and its negative. Their
setters remain intact, and observed nonzero values remain reportable diagnostics.
**A zero is never evidence that no tear occurred.**

The [standing harness](../anomaly-census/README.md) now demonstrates the proposed
replacement observations and states their limits in every report. Wine fault
totals and FEX decoder rejection buckets observe faults and rejected decoding;
they **do not cover every silent partial atomic write**. There is no general
atomicity or fault-free-runtime claim. The Phase-0 correction note now says so.

## Source audit and decision

The measured FEX source is unmodified `77f9ae5d8307fb127cc175725fdbbebbeef10641`
from `alloy/task-37-anomaly-telemetry`, copied to a private branch. It is not the
shared live `alloy/task-8-dispatcher-teb` revision. All four tear setters in
`FEXCore/Source/Utils/ArchHelpers/Arm64.cpp` require the upper constituent CAS to
succeed and the lower CAS to fail. The [source audit table](../anomaly-census/README.md#why-retire-the-flags)
records the widths and setter locations.

The existing uncontended boundary-crossing probe cannot force an intervening
writer between those stores. A stress race would not supply a deterministic
positive control. No claim is made that the partial-commit state is unreachable.
The engineering decision is to retire that signal from clean-run claims, not to
leave its eligibility contingent on interpreting another zero. Directly setting
a flag would test reporting rather than the guest-to-helper path and is not
presented as calibration.

## Measured controls

Host: ARM64 macOS **27.0.1 (26A434)**. Final fresh-prefix run:
`spikes/CPU-001/work/anomaly-census-runs/run-6bhzwgrt/` in the task worktree.
The committed [evidence manifest](../anomaly-census/evidence.json) contains the
full control summaries, hashes, source identities and coverage declaration.

| Guest control | Observed result |
| --- | --- |
| Access-violation negative | 0 caught; access-violation increase 0 |
| Access-violation positive | 64 caught; access-violation increase exactly 64 |
| Valid decoder negative | NOP/RET succeeds; no outcome bucket set |
| Invalid decoder positive | One caught illegal instruction; `invalid-no-dispatcher=1`; reported RIP matches the allocated `06 c3` stub |
| Unimplemented-bucket positive | One caught illegal instruction; `unimplemented=1` for `f0 90 c3` |
| Aligned atomic negative | 0 alignment faults; both calibrated split flags clear |
| Split locked add | 2,000 alignment faults; both split flags equal 1 |
| Split 32-bit CAS | 2,000 alignment faults; both split flags equal 1 |
| Split 64-bit CAS | 2,000 alignment faults; both split flags equal 1 |

All nine guests exit 0, load the actual builtin FEX in the same guest process,
and complete within their 60-second deadline. The fault increase is measured
against a pre-loop snapshot, so startup access violations are not misreported
as control faults. Wine emits a complete exit snapshot after each guest result.
Each complete ordinary-fault snapshot satisfies
`segv-entries = resolved + access-violations`; separately accounted alignment,
x18-backstop and translated-store paths are not silently included in that identity.

The decoder controls are separate binaries: an unused positive branch in a
single executable could still be counted by FEX's reachability walk. The
unimplemented bucket is calibrated using an illegal LOCK prefix on NOP, not a
claim that valid NOP is unsupported. Counts describe decodes, not executions.

The initial 100-decode dump interval reproduced the timing problem from result
22: the deliberate rejection could occur after the last sample. Calibration
therefore uses interval 1 and requires a complete post-operation decoder sample.
The final decoder totals satisfy `total_decode_calls = decoded + outcomes`.
This verbose setting is not a performance configuration.

Twelve mutations of the actual final logs are rejected: missing census,
truncated census, absent builtin load, numerically increased access-violation
counts, a missing split flag, either missing decoder outcome, missing process
baseline, stale decoder samples, another process's fault census, timeout and
nonzero exit. Offline replay of the final evidence also passes. A dead or
unsampled instrument cannot qualify through an absent line or zero.

## Private runtime integration

Wine is the frozen fault-census source at
`619c4c0e1ed7b0fb964c0b29388ff227a7dadf72`, with the committed
[calibration patch](../anomaly-census/wine-census-resume.patch). It reuses #111's
macOS JIT resume repair. Its bridge header is byte-identical to #111's verified
header (`a1e76d4f38f56d102a165107a09c379206ba7aa832a2a513272193e5b0bad973`).

The integration also accounts for the handled `STATUS_RETRY` return as a
resolved fault before the census checkpoint. Returning without that increment
would break the ordinary-fault conservation identity. The runtime was built
only in the private clone, with the pinned LLVM-MinGW toolchain, FEX telemetry
enabled, LTO disabled, the existing Darwin TEB overlay, and 16 KiB host guards.
No FEX source was edited and no new FEX fork commit was created.

| Identity | SHA-256 |
| --- | --- |
| Wine calibration patch and complete private source diff | `776be1aef6d864d1416a6c0cd81d3125eeeb453469efc39c1509a3a5bb42bc0f` |
| Builtin FEX DLL | `ab3dcc0412b122272a631e0471e991a335f9536a9f87d69221174e05cc3ebd14` |
| Repaired census `ntdll.so` | `6d31fe650134833ebe6fadee554e7d7a4e9fd34244cbf77fa5f95237aa1e58e7` |
| Complete selected runtime inventory, before and after | `090efb95efe8c1d6b4ac67593716d51e561ed8417fb00f1119741871a8e8ba42` |
| Final raw report | `2a8cc41e3494099a91800504d03c04579f4a9307eb7d3cb4a266fc7d17803ff1` |

The manifest additionally binds the guest executables, compiler, actual test
inputs, raw logs, overlay files, and CMake cache. These are reproducibility and
local integrity records, not a signed build attestation.

## Preservation and limits

Both shared runtime inventories are unchanged:

- Live `build-2`: 21,652 entries,
  `00640da69a959497db45a5da2ee1086392b2e9faa7337448f835e3313ce7ce0d`.
- Frozen census `wine2`: 7,523 entries,
  `26d20236e13ef2a2c4632dd897afdfd8b756df553d053a6a9fd1b8eeac81ebc6`.

Shared FEX remains clean on `alloy/task-8-dispatcher-teb` at `ad94231`.
Shared Wine remains on `alloy/spike-wine-001` at `420c70b`, and its inherited
signal/RPC edits retain diff hash
`3cf78f47e3e734bc473363b1add23fdaf272c1eaf6efccb2b088fc433ddff526`.
No title run, shared-runtime installation, upstream contribution, or excluded
implementation-source inspection was needed.

One additional fresh-prefix attempt, `run-yokdtqcp`, timed out in `wineboot`
at 120 seconds before any guest control ran. It is recorded as **FAIL** in the
evidence manifest, its runtime inventory is unchanged, and it is not counted
as successful calibration. A subsequent new-prefix run completed all nine
controls. The cause of that isolated prefix-initialization timeout was not
established; this task does not claim general Wine startup reliability.

Most importantly, passing fault/decoder controls does not establish the absence
of silent tearing. That dimension is explicitly unmonitored, rather than
appearing monitored by an uncalibrated zero.
