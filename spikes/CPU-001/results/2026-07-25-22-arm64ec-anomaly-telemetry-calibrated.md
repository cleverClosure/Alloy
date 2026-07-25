# CPU-001 result 22 — ARM64EC anomaly telemetry fires; result 19 sampled before the anomaly, and CAS-tear zeros remain inadmissible

**Author:** Timur Isaev
**Date:** 25 July 2026
**FEX:** `alloy/task-37-anomaly-telemetry` @ `77f9ae5`
(`eee1aa9` implementation) ·
**Wine:** frozen issue-#12 census build,
`alloy/task-12-fault-census` @ `619c4c0` ·
**Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

Issue #37 started from a true observation and the wrong causal explanation.
Result 19 saw zero telemetry around guests that later executed 2,000 deliberate
unaligned locked operations. It concluded the flags did not fire. The raw log
shows that every telemetry dump happened during startup decoding, **before the
atomic loop ran**; the loop decoded no new blocks, so it never triggered
another interval dump.

The ARM64EC census now:

1. emits an explicit `process-init` zero baseline;
2. checks FEX's atomic telemetry values immediately after every unaligned-access
   helper invocation; and
3. logs only newly observed bits from that checkpoint.

The rebuilt calibration guest gives the required positive and negative controls:

| mode | exit | observed telemetry |
| --- | ---: | --- |
| `clean` | 0 | baseline `nonzero=0`; no change |
| `splitlock` | 0 | `64byte Split Locks=1`, `16byte Split atomics=1` |
| `splitcas32` | 0 | the same two flags |
| `splitcas64` | 0 | the same two flags |
| `split16` | 2 | unsupported `Unhandled JIT SIGBUS CASPAL`; no positive calibration |

The split flags therefore **do fire on ARM64EC and are happened-at-least-once
flags, not counts**. The CAS-tear flags remain unusable for a clean-run claim:
their setters describe a rare partial two-step commit, not an ordinary
cross-boundary CAS, and no deterministic positive control has made one fire.
Use the Wine fault census plus decoder invalid/unimplemented buckets for that
unqualified anomaly dimension.

## 1. Why result 19 read zero

The old path emitted telemetry only as part of `Alloy::Census::Dump`, reached
after every configured number of **decodes**. `telemetry_probe` completes its
startup decoding before entering the 2,000-iteration atomic loop. Its historical
log has the interval dumps first, followed by 2,000 handled alignment faults and
then the guest's success line. There is no telemetry sample after those faults.

So "all sampled values were zero" was accurate; "the values stayed zero through
2,000 anomalies" was not. The experiment observed the wrong time window.

The issue's proposed gate explanation was also wrong. A translated x86
`lock add`, `lock cmpxchg` dword, and `lock cmpxchg` qword can all fault on the
generated Arm64 atomic and reach
`FEXCore::ArchHelpers::Arm64::HandleUnalignedAccess`. At a dword address two
bytes before a 64-byte boundary, the helper sets both split classifications.
The new post-helper checkpoint makes that state visible immediately.

## 2. Implementation

`eee1aa9` adds two fork-local census operations:

- `DumpTelemetry` emits every non-zero value plus an explicit snapshot summary,
  so absence of value lines is no longer ambiguous with absence of a dump.
- `DumpTelemetryChanges` atomically remembers already reported bits and emits
  only a newly observed flag or mask.

ARM64EC `ProcessInit` takes the baseline after logging is initialized. The
unaligned exception path calls the change checkpoint after the helper has had a
chance to set telemetry, including when the helper ultimately passes the
exception through. The checkpoint is silent unless `ALLOY_CENSUS` is set.

The output deliberately says `value` and
`(flag-or-mask, not a frequency)`. There are no
`FEXCORE_TELEMETRY_INC(...)` call sites. Anomaly sites use
`FEXCORE_TELEMETRY_SET(..., 1)`; crash telemetry uses `_OR` as a bitmask.

Representative positive output:

```text
ALLOY_CENSUS telemetry_snapshot reason=process-init nonzero=0
ALLOY_CENSUS telemetry_value reason=unaligned-access value=1 name=64byte Split Locks (flag-or-mask, not a frequency)
ALLOY_CENSUS telemetry_value reason=unaligned-access value=1 name=16byte Split atomics (flag-or-mask, not a frequency)
ALLOY_CENSUS telemetry_snapshot reason=unaligned-access nonzero=2 changed=2
telemetry_probe splitlock iterations=2000 misaligned=1 ok
```

## 3. What the probe does and does not prove

The probe's old `castear32` and `castear64` names overclaimed. They perform a
cross-boundary CAS, which calibrates the split flags but does not guarantee a
tear. They are now advertised as `splitcas32` and `splitcas64`; the old names
remain accepted only so historical invocations do not break.

FEX sets a CAS-tear flag only after one constituent store of its emulated
operation succeeds and a later store fails because memory changed in between.
That requires a precisely timed competing writer. Two thousand uncontended
cross-boundary CAS operations correctly leave the tear flags at zero, but that
zero does not prove their positive path works.

The `split16` mode is a separate red guard. Current ARM64EC handling rejects the
64-bit-pair CASPAL sequence before it reaches a split setter:

```text
ALLOY_CENSUS telemetry_snapshot reason=process-init nonzero=0
Unhandled JIT SIGBUS CASPAL: ... Instruction: 0x4866ff2a
Unhandled non-JIT atomic
```

That is exit 2, not a telemetry pass. Keeping the mode makes future support
visible and prevents it from being silently counted as covered.

Therefore:

- positive `64byte Split Locks` / `16byte Split atomics` values from supported
  32- and 64-bit handled operations are admissible, with flag semantics stated;
- no telemetry value may be reported as a frequency;
- a zero CAS-tear value is not admissible evidence of no tears; and
- the general anomaly census continues to use the exact Wine fault census and
  decoder invalid/unimplemented buckets.

## 4. Reproduction and isolation

The probe was rebuilt with the pinned LLVM-MinGW toolchain and `-mcx16`.
`libarm64ecfex.dll` was built from `77f9ae5` with
`ENABLE_OFFLINE_TELEMETRY=ON`. The run used:

```text
ALLOY_CENSUS=1
ALLOY_CENSUS_INTERVAL=250000
FEX_SILENTLOG=0
telemetry_probe.exe clean|splitlock|splitcas32|splitcas64|split16
```

A `splitlock` control with `ALLOY_CENSUS` absent also exited 0 and emitted only
the guest's success line; the fork-local checkpoint remained silent.

Artifact identities:

| artifact | SHA-256 |
| --- | --- |
| committed FEX build | `98cb35abfc5143265d717b0621b87b07e1cdde3a09ab63a2b7d4f32ea1b9dd28` |
| rebuilt probe | `c8118c9913134cf60beb76ae0f2ba22ce2c5e7e6f221dcae2c5510e6e2b71658` |
| frozen census Wine `ntdll.dll` | `edf0638235e44b8254ea3ddb1580c1d33d139e9c28a08efd9b06e8ec3135a369` |
| untouched frozen-census FEX DLL | `0924c8a2db7bc4a95f13ee53a11591c6905111945f884a65420075f018069c12` |
| untouched active WINE-001 FEX DLL | `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` |

Wine prefers its build-tree builtin over `WINEDLLPATH`. To avoid modifying the
shared build used by active work, the frozen CPU census Wine tree was cloned
copy-on-write under `/private/tmp`; only that clone received the task DLL.
The original census DLL and the active WINE-001 build DLL retained their
pre-task hashes.

## Doctrine reinforced

Calibration is not only "make the instrument fail on purpose." **The read must
occur after the event.** A perfect flag sampled before a loop is
indistinguishable from a dead flag sampled after it, and 2,000 independently
counted faults do not repair that temporal mismatch.
