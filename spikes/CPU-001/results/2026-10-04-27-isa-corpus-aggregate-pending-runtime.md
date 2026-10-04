# CPU-001 result 27 — complete corpus command; FEX acceptance remains blocked

**Author:** Timur Isaev  
**Date:** 4 October 2026  
**Issue:** #104 milestone 5 preparation; runtime dependency #111

## Aggregate status

All thirteen required family binaries now exist and cross-compile. Their
252 operation forms/invariants exercise 373,464 seeded cases per clean run.
All available native reference, host atomic and independent Rosetta checks
passed, with named mutation failures. x87 is guest-side self-checked only;
there is no arm64 floating-point comparison for that family.

**No current FEX run is reported.** The macOS 27 runtime failure in #111 still
prevents observing the required guest outcomes. Milestones 2–5 therefore remain
pending. The following checksums are the verified local oracle/self-check pins,
not invented FEX observations.

| Family | Cases | Clean pin | Corrupted-reference pin | FEX clean/mutation |
| --- | ---: | --- | --- | --- |
| sse2 | 12,736 | `21ba41417def5d07` | `eb480915973927bd` | NOT RUN |
| sse | 17,216 | `1243a236db34df2f` | `55cf1a60181340ae` | NOT RUN |
| sse3 | 8,256 | `a0918c8c7fafcfd9` | `5305bc4225f49774` | NOT RUN |
| ssse3 | 24,576 | `ce9645ed60d9d174` | `89914f4da68752d8` | NOT RUN |
| sse41 | 24,128 | `6cfd121cde334cde` | `6011bfd1cf108682` | NOT RUN |
| sse42 | 10,176 | `49c8cba45643ca58` | `393ef08fb8605058` | NOT RUN |
| avx | 25,728 | `732fe5b38fa3c408` | `64943f963264b421` | NOT RUN |
| avx2 | 33,664 | `589ca5662342c316` | `5a9e8298190dc946` | NOT RUN |
| bmi1 | 33,324 | `5a36ed60bc454d14` | `20eadcbd0e12aa65` | NOT RUN |
| bmi2 | 44,432 | `0fa7cb1768b0cd21` | `c3df897b1512a714` | NOT RUN |
| flags | 99,620 | `dabc6bdd3b7d41af` | `93c7f7c6028d282b` | NOT RUN |
| atomics | 35,512 | `faad3e1498581db0` | `2476aea558e8f030` | NOT RUN |
| x87 | 4,096 | `cc376fd87725cdb0` | `95eec97d57d7a340` | NOT RUN |

SSE2 uses seed `a1c0ffee5eed0001`; the twelve newer families use
`a1c0ffee5eed0003`. Arithmetic NaN normalization and individual instruction
scope are documented in [result 25](2026-10-04-25-vector-corpus-native-verification.md).
BMI, condition flags, contention and x87 boundaries are in
[result 26](2026-10-04-26-integer-corpus-native-verification.md).

## One standing terminal command

Once #111 supplies a working x64 runtime, run from a fresh terminal at the
repository root:

```sh
bash spikes/CPU-001/testcases/build-corpus.sh --isa-corpus
```

This is the required end-to-end command. It prepares both clean and corrupted
PEs and native references, creates a unique private Wine prefix under
`spikes/CPU-001/work/isa-corpus-runs/`, proves the unregistered-prefix refusal,
registers FEX, then runs every family and the additional contended-ticket
corruption control. It never builds into Wine/FEX or installs an emulator into
the prefix. Each attempt has its own retained logs and `aggregate.json`.

The original compile-only command still builds the entire 34-binary CPU corpus:

```sh
mkdir -p spikes/CPU-001/work/corpus
bash spikes/CPU-001/testcases/build-corpus.sh spikes/CPU-001/work/corpus
```

It requires the existing llvm-mingw toolchain on PATH, as before. The aggregate
runner also accepts `--toolchain`, `--wine-build`, `--wine-source` and
`--fex-source`; the existing `ALLOY_*` overrides are supported.

The available portion was executed end to end with:

```sh
bash spikes/CPU-001/testcases/build-corpus.sh --isa-corpus --native-only --rosetta
```

Its report contains all thirteen families and explicitly records every FEX
outcome as `NOT RUN`, with `required_fex_complete: false`. `--rosetta` adds
separate x86 Mach-O checks, including the legacy SSE2 control; it never stands
in for Wine/FEX. The command without `--native-only` has **not** been run since
the confirmed runtime blocker. It cannot be claimed as the milestone's required
fresh-terminal FEX reproduction yet.

## Gates on a real run

Before every Wine invocation the runner reads the process table, rejects
runtime contention, records Wine/FEX source SHAs and dirty paths, and hashes
the loader, wineserver, Unix ntdll and builtin FEX DLL. Source trees are only
queried through git metadata. Binary hashes must remain the same throughout.
Only the private prefix's server is stopped, with bounded cleanup.

The full runtime directory is inventoried before setup and in a finally block
after cleanup, including failure paths. The inventory includes sorted relative
names, file bytes, modes and symlink targets; source symlinks are not followed.
Files changing while being hashed are rejected. The before/after inventories
must match exactly. Read-only inventory validation on the actual idle build-2
covered 21,652 entries and reproduced SHA-256
`00640da69a959497db45a5da2ee1086392b2e9faa7337448f835e3313ce7ce0d`
twice. That validates the inventory mechanism, not a nonexistent FEX run.

A module lookup does not establish what ran. Each guest must emit the actual
`loaddll` event identifying `libarm64ecfex.dll` as builtin. The known earlier
fault-storm log satisfies this load check and is still rejected as a timeout:
a loaded DLL and a completed correctness test are separate requirements.

The reader independently checks exit status, complete family/operation
inventory, expected case count, checksum, mutation identity and named failures.
SSE2's guest mutation must show all 236 instruction mismatches plus its hand
vector; the hand vector alone cannot pass it. The new family readers likewise
require the exact known mismatch counts. The atomics ticket corruption gets
its own required guest run and exact broken-invariant verdict.

A success aggregate requires every expected family, both outcomes, complete
per-run metadata, unchanged artifacts and runtime inventory, actual builtin
loads, and the additional ticket control. A native-only report, missing row,
extra row, altered checksum, timeout, crash, omitted metadata or changed runtime
cannot satisfy it. Time and diagnostic volume are bounded. Interrupts terminate
the invocation's process group and invoke private-prefix cleanup.

## Controls actually executed

```sh
bash spikes/CPU-001/testcases/build-corpus.sh --isa-corpus --selftest
```

The reader's four positive and sixteen negative cases pass. Another 21 checks
exercise inventory mutation, added files, link changes, contention parsing,
lookup-only/native-image refusal, lost SSE2 failures, aggregate omissions and a
real bounded subprocess timeout.

Three additional **synthetic Wine** workflows execute a temporary Python loader
and server, with controlled guest-output fixtures. They exercise the entire
orchestration path, private-prefix cleanup and final inventory checks. The
complete synthetic path succeeds; lookup-only traces and a deliberate runtime
write are rejected. No emulator or Windows guest is executed by these controls,
and none of their simulated results appears in the observed-outcome table.

A separate native-only aggregate was interrupted during a compiler invocation.
It retained the interruption error, left FEX completion false and all FEX rows
at NOT RUN, and left no child process from that attempt running.

The actual native aggregate, clean and corrupted cross-builds, independent
Rosetta runs, opcode inspections and repository lint passed. No CI job was
added. The final acceptance evidence still requires the restored runtime.

## Scope closure

Issue #78 remains open, unmodified and outside this corpus. No CAS-tear telemetry
was read or changed. This work contains only first-party test generators,
harnesses and reports. The shared Wine/FEX source and build artifacts were
preserved. Completing #104 still requires real clean/mutation FEX outcomes for
every family and an unchanged runtime inventory around that full run.
