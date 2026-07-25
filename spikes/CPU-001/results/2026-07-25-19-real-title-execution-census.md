# CPU-001 result 19 — real-title census: the instruments had to be built and three of them lied first, and the x18 tax is 300,763 per title boot rather than the ~250 result 17 measured

**Author:** Tim Isaev
**Date:** 25 July 2026
**FEX:** `alloy/task-12-census` @ `53d2311` ·
**Wine:** `alloy/task-12-fault-census` @ `619c4c0` ·
**Title:** *The Life and Suffering of Sir Brante* build 24280929, exe SHA-256 `1fb707b1…f95455` ·
**Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

Issue #12 asked to characterize game-scale execution: instruction mix, fault
rates, cache behaviour, anomalies. Almost none of that was measurable when the
task started, and the work divides in two: making instruments that report the
quantity they claim, and then reading them.

- **Nothing counted instructions.** A per-thread census now tallies decoded
  forms (§1). It counts *decodes*, not executions, by a wider margin than
  expected, and §1 states exactly what that means.
- **Fault counters were samplers, not counts.** Every one printed the first N
  then every 100,000th. They now also report exact totals, and the totals obey
  a conservation law (§2).
- **FEX's anomaly telemetry has never once fired on this path, and cannot be
  quoted** (§3). It is compiled in, it was never emitted, and when finally
  emitted it stayed at zero through 2,000 deliberately provoked anomalies.
- **The x18 backstop absorbs 300,763 faults in one title boot** (§4). Result 17
  measured ~250 per process on the synthetic corpus and concluded the cost was
  "startup-shaped, not hot-path". At title scale that conclusion does not hold,
  and #8 was closed on it.
- **The translated-JIT-store handler from #30 fires 71,065 times per boot**
  (§4) — load-bearing, not a corner case.
- Sample is **n=1**: one title, because it is the only entitled build installed
  and hash-certified. §6 says what that does and does not support.

## 1. Instruction census — and what "decoded" means

`Decoder::DecodeInstruction` is the single choke point through which every
decode passes, so the tally sits there: one `unordered_map` per thread, keyed
by `X86InstInfo*`. Each thread owns its `Decoder` (`Core.cpp` builds one per
`InternalThreadState`), so there is no lock and no atomic on the decode path.
Retired threads merge into an accumulator rather than being dropped — the first
version dropped them, which on a 36-thread title would have silently discarded
most of the run.

**It counts decodes, not executions, and the gap is large.**
`DecodeInstructionsAtEntry` walks branch targets and decodes the whole
statically-reachable region from an entry point, and `CheckIfCacheable` walks
it again. Demonstrated with a guest whose three mode functions are chosen by
`argv`:

| mode | crc32 executed | total decodes | CRC32 decodes |
| --- | --- | --- | --- |
| `loop` | 1,000,000 | 920 | 74 |
| `unrolled` | 1,000,000 | 920 | 74 |
| `quiet` | **0** | 920 | **74** |

The mode that executes no `crc32` at all reports all 74 of the binary's `crc32`
sites, and all three produce byte-identical profiles. So this answers "which
x86 forms does the reachable code contain", which is what #12 asks, and it is
**not** an execution profile. Counting executions would need a counter in the
hot path, which would change what it measures.

Guest output is byte-identical with the census on and off, so the instrument
does not move the numbers.

### Title result

Two million decodes into the headless boot, 36 live threads:

| count | form | | count | form |
| ---: | --- | --- | ---: | --- |
| 851,548 | `MOV` | | 62,721 | `JZ` |
| 140,374 | `LEA` | | 51,854 | `JNZ` |
| 136,357 | `CALL` | | 50,868 | `JMP` |
| 98,736 | `ADD` | | 45,211 | `XOR` |
| 85,209 | `CMP` | | 35,524 | `SUB` |
| 78,757 | `TEST` | | 35,443 | `POP` |

431 distinct table entries across 279 distinct mnemonics. `MOV` alone is ~43%
of decoded code. Nothing exotic dominates: this is ordinary integer and
control-flow x86, which is the reassuring answer for a translator.

**One decode in two million could not be dispatched.** Named rather than
counted, because a bare count cannot be filed:

```text
ALLOY_CENSUS invalid #0 rip=0x6ffff9ce6658 op=0x8f opraw=0x8f modrm=0xe8
                       size=0 table=(none) bytes=8f e8 78 c2 ec 0e 41 c1
```

`0x8f` with a non-zero modrm reg field is the XOP prefix — an AMD-only set FEX
does not implement. But the address sits in the system-DLL range
(`0x6ffff…`), not the game image, which loads at `0x140000000`. So this is
more likely the region-walking decoder reading non-x86 bytes than a genuine XOP
instruction in the title, and it is filed as needing attribution rather than as
a confirmed translation gap.

## 2. Fault census — exact totals, and a conservation law

The existing counters are unchanged; they now read their value from a shared
census array, so a sampler and the census cannot disagree, and exact
cumulative totals are emitted separately.

Validated twice against guests whose answer is fixed by construction:

| guest | known answer | census |
| --- | --- | --- |
| `seh_repeat hammer` | 800 caught access violations | 806 (800 + 6 startup) |
| `telemetry_probe splitlock` | 2,000 unaligned locked ops | 2,000 align-faults exactly |
| `telemetry_probe clean` | 0 (aligned control) | 0 align-faults |

The stronger check is structural. Every fault entering the handler leaves on
exactly one accounted path, so `segv-entries` must equal
`resolved + access-violations`. On the title:

```text
segv-entries 200000 == resolved 199944 + access-violations 56
```

The first title run missed by exactly one, because the census tick sat between
the segv increment and the classification; the in-flight fault was counted as
neither. Moving the tick after classification makes the identity hold exactly.
That conservation is better evidence than any single number matching, because
it breaks under double counting, a dropped path, or a race.

## 3. FEX's anomaly telemetry cannot be quoted

`FEXCore::Telemetry` already tracks the anomaly classes #12 wants — split
locks, split 16-byte atomics, 16/32/64/128-bit CAS tears, EVEX use,
non-canonical addresses. It is compiled into the ARM64EC build
(`ENABLE_OFFLINE_TELEMETRY=ON`). **Nothing ever emitted it:**
`Telemetry::Initialize`/`Shutdown` are called only from `FEXInterpreter` and
`LinuxEmulation`, so on this path the counters accumulated and were discarded
at exit. They are now emitted through the log.

Two findings follow, and both are disqualifying for census use:

1. **They are flags, not counts.** Every setter in the tree is
   `FEXCORE_TELEMETRY_SET(Type, 1)` or `_OR` for a bitmask; there is no
   `FEXCORE_TELEMETRY_INC` anywhere. "1 split lock" would mean "split locks
   occurred, frequency unknown".
2. **They do not fire when the anomaly does.** `telemetry_probe` produces
   exactly 2,000 alignment faults per run from unaligned locked operations —
   confirmed independently by §2's counter, with 0 in an aligned control — and
   every telemetry value stayed zero throughout. The gate explains it:
   `TYPE_HAS_SPLIT_LOCKS` is set only inside the CAS emulation helpers and only
   for an address at one specific offset in a 64-byte line, so a `lock add`
   never reaches it.

**A zero from these counters is not evidence of a clean run.** The anomaly
dimension of this census therefore comes from §2's fault totals and the
decoder's invalid/unimplemented buckets, which are trustworthy, and not from
telemetry. Filed as its own issue.

## 4. What the title actually costs

Headless boot to the game-manager and asset-loading stage, 150 s cap:

| counter | per boot |
| --- | ---: |
| segv entries | 200,000 |
| resolved faults | 199,944 |
| access violations left for the guest | 56 |
| alignment faults | 1,943 |
| **x18 backstop absorbs** | **300,763** |
| **translated JIT stores emulated (#30)** | **71,065** |
| JIT stores rejected (any reason) | 0 |

Two of these change existing conclusions.

**The x18 tax.** Result 17 measured ~250 absorbs per process across the
synthetic corpus, concluded the residual was "a fixed startup-shaped cost, not
a hot-path one" at "roughly 0.00025% of one `cpu_throughput` workload", and
# 8 was closed as premise-not-supported partly on that basis. A real title boot
takes **300,763** — three orders of magnitude more, and more than the number of
segv entries, because these are absorbed before that counter. Result 17's
*measurement* stands; its *extrapolation to scale* does not, and it could not
have, because the corpus has no 36-thread Unity/Mono workload. Filed for
re-examination.

**The JIT-store handler.** #30's emulation of translated stores across separate
MAP_JIT views fires 71,065 times in one boot, with zero rejections. Before #30
each of those was a livelock. That the title runs at all rests on this path
being taken seventy thousand times, which is a stronger justification for the
change than the issue that motivated it claimed.

The 56 access violations and 1,943 alignment faults are unremarkable and
expected for a Mono runtime.

## 5. Cache behaviour — not measured

# 12 lists cache behaviour among the census dimensions. It is not in this
result. FEX's code cache is gated behind `ENABLECODECACHINGWIP` and
`ImageTracker.cpp` still carries `CodeCacheConfigId = 0; // TODO`, so the cache
is not invalidated on a FEX rebuild; measuring hit rates against a cache with
known-broken invalidation would produce a number no one should act on. Recorded
as not-measured rather than estimated.

## 6. What n=1 supports

One title, because *Sir Brante* build 24280929 is the only entitled build
installed and hash-certified. That is enough to state, with evidence, that the
translator's decoded mix on a real Unity/Mono title is ordinary integer and
control-flow x86; that one boot costs ~300k x18 absorbs and ~71k emulated
translated stores; and that the fault accounting is internally consistent at
that scale. It is not enough to claim anything about titles in general, and
particularly not about engines other than Unity 2018.3. D1's remaining proof is
satisfied for this title and no more.

## Doctrine reinforced

Result 17 drew the lesson that a rate-limited counter is not a count. This task
found the same failure three more times, in three different instruments, and
each was caught only by insisting the instrument report the quantity it claims
before reading anything from it: the census that measured nothing because Wine
loads its own builtin `libarm64ecfex` ahead of the prefix copy (the same stale
image that cost result 18 a session); the census that dropped every exited
thread; the telemetry that reads as a count and is a flag, and stays zero
through 2,000 real anomalies. The general form is that an instrument is
evidence only after it has been made to fail on purpose — and the corollary
this result adds is that a measurement's *scale* is part of its claim: ~250
absorbs on the corpus and 300,763 on a title are the same instrument, honestly
read, supporting opposite conclusions.
