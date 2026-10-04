# CPU-001 result 27 — complete ISA corpus verified through FEX

**Author:** Timur Isaev  
**Date:** 4 October 2026  
**Issue:** #104 milestone 5; isolated runtime repair #111

## Observed aggregate

All thirteen required families pass through FEX on this M2 Pro running
macOS 27.0 (26A428). Their 252 operation forms/invariants exercise 373,464
seeded cases per clean run. Every clean guest exits 0 with zero failures.
Every deliberately corrupted guest exits 1 with the exact named mismatches
and checksum required by its manifest. The additional atomic ticket corruption
also fails as expected, at checksum `cf73f23dd9bcc99f`.

All 27 required guest verdicts pass. Each has an actual builtin FEX load event;
a timeout, crash, arbitrary nonzero exit or matching checksum alone cannot
satisfy the reader. Native references and independent Rosetta instruction
checks pass separately. x87 is guest-side self-checked only, with no arm64
floating-point comparison.

| Family | Cases | Clean pin | Corrupted-reference pin | Observed FEX clean / mutation |
| --- | ---: | --- | --- | --- |
| sse2 | 12,736 | `21ba41417def5d07` | `eb480915973927bd` | PASS / expected FAIL |
| sse | 17,216 | `1243a236db34df2f` | `55cf1a60181340ae` | PASS / expected FAIL |
| sse3 | 8,256 | `a0918c8c7fafcfd9` | `5305bc4225f49774` | PASS / expected FAIL |
| ssse3 | 24,576 | `ce9645ed60d9d174` | `89914f4da68752d8` | PASS / expected FAIL |
| sse41 | 24,128 | `6cfd121cde334cde` | `6011bfd1cf108682` | PASS / expected FAIL |
| sse42 | 10,176 | `49c8cba45643ca58` | `393ef08fb8605058` | PASS / expected FAIL |
| avx | 25,728 | `732fe5b38fa3c408` | `64943f963264b421` | PASS / expected FAIL |
| avx2 | 33,664 | `589ca5662342c316` | `5a9e8298190dc946` | PASS / expected FAIL |
| bmi1 | 33,324 | `5a36ed60bc454d14` | `20eadcbd0e12aa65` | PASS / expected FAIL |
| bmi2 | 44,432 | `0fa7cb1768b0cd21` | `c3df897b1512a714` | PASS / expected FAIL |
| flags | 99,620 | `dabc6bdd3b7d41af` | `93c7f7c6028d282b` | PASS / expected FAIL |
| atomics | 35,512 | `faad3e1498581db0` | `2476aea558e8f030` | PASS / expected FAIL |
| x87 | 4,096 | `cc376fd87725cdb0` | `95eec97d57d7a340` | PASS / expected FAIL |

SSE2 uses seed `a1c0ffee5eed0001`; the twelve newer families use
`a1c0ffee5eed0003`. Arithmetic NaN normalization and individual instruction
scope are documented in [result 25](2026-10-04-25-vector-corpus-native-verification.md).
BMI, condition flags, contention and x87 boundaries are in
[result 26](2026-10-04-26-integer-corpus-native-verification.md).
The table contains observed FEX checksums, each equal to its independently
established reference or guest-self-check pin.

## Reproduce from a fresh terminal

From the repository root, select the already-built isolated runtime explicitly:

```sh
PYTHONDONTWRITEBYTECODE=1 \
PATH="/Users/cleverclosure/Developer/Alloy/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin:$PATH" \
  bash spikes/CPU-001/testcases/build-corpus.sh --isa-corpus --rosetta \
    --wine-build /private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/wine-build \
    --wine-source /private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/wine-source \
    --fex-source /private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/fex-source
```

This exact target completed end to end in a fresh shell. Its retained evidence
is `/private/tmp/alloy-104-m5/spikes/CPU-001/work/isa-corpus-runs/run-v9gv7ups/`.
`aggregate.json` records `required_fex_complete: true`,
`registration_control: true` and `runtime_unchanged: true`.
The earlier direct-runner confirmation is in `run-i5v8lx3u/`; both runs produce
every checksum above. Guest binaries, native/Rosetta output, complete guest
logs, source revisions and before/after runtime inventories are retained.

The command prepares clean and corrupted PEs and native references, creates a
new private prefix under `spikes/CPU-001/work/isa-corpus-runs/`, proves the
unregistered-prefix refusal, registers the existing FEX DLL and runs every
guest. It never builds Wine/FEX or installs an emulator into the prefix. It
loads the selected build's builtin DLL and validates its actual load event.
The original compile-only command still builds all 34 CPU-001 binaries:

```sh
mkdir -p spikes/CPU-001/work/corpus
bash spikes/CPU-001/testcases/build-corpus.sh spikes/CPU-001/work/corpus
```

Keep the existing llvm-mingw toolchain on PATH for that compile-only command.
The aggregate also supports `--toolchain` and the corresponding `ALLOY_*`
overrides. `--native-only` leaves all FEX rows `NOT RUN` and completion false;
it is a preparation mode, never a substitute for this acceptance run.

## Runtime identity and preservation

The original shared runtime still lacks the Wine signal-resume repair.
Tests select #111's private copy read-only. Its patch and application
instructions are in [result 28](2026-10-04-28-macos27-jit-signal-resume.md).

| Identity | Revision / SHA-256 |
| --- | --- |
| Clean private Wine source | `f0937d595166631dd00eaab31fef4fb5a6f37031` |
| Unchanged private FEX source | `ad942313dca79d32133cceaaf617016821e3b952` |
| Copied loader | `d77a3f35bc0941b43226cb0f761f811051b33a057b79ab1f4324e4a29404a0dd` |
| Copied wineserver | `7cf50a002813624d7a7cbbdd13f0fc1205844b4603a81b77c919503e159bb728` |
| Repaired ntdll | `815e465b80dca0802770a3ae36471af344ee1cae0c280d93d3b1308abbac8a89` |
| Actual builtin FEX DLL | `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` |
| Selected runtime before = after | `8f0fa54a52cdd63ac7eb8fb722f210a375649e96fbd0cfadaf727423c7fa763a` |
| Shared runtime before = after | `00640da69a959497db45a5da2ee1086392b2e9faa7337448f835e3313ce7ce0d` |

Each full directory inventory covers 21,652 entries: sorted names, modes,
file contents and symlink targets. Source symlinks are never followed. The
shared inventory was rechecked after the final aggregate run and matches the
pre-repair baseline. Shared Wine's branch and inherited two-file diagnostic
diff are preserved; shared FEX remains clean on its original branch.

Before each of the 30 Wine invocations, the final runner checks both the selected
and shared runtime process inventories, and records source SHAs/dirty paths
and four binary hashes. A failed process query refuses execution. Every run
records both checks as idle. Only this private prefix's server is stopped;
cleanup, guest execution and diagnostic volume have finite bounds. A finally
block inventories the selected runtime on success and failure.

The unregistered-prefix control explicitly selects Wine's builtin `xtajit64`
refusal stub. It must log an actual stub load, refuse x64 execution and show
no FEX load. Forcing a nonexistent native stub fails earlier during kernel32
loading and cannot pass this control. Cold service startup uses the same
60-second bound as registered guests; a timeout is always a failure.

## Harness controls and scope

```sh
bash spikes/CPU-001/testcases/build-corpus.sh --isa-corpus --selftest
```

The reader's four positive and sixteen negative cases pass. Another 21 controls
check inventory mutation, added files, changed links, contention parsing,
lookup-only/native-image refusal, missing SSE2 failures, aggregate omissions
and a real bounded subprocess timeout. Four synthetic Wine workflows exercise
the entire orchestration: the valid path passes; lookup-only FEX evidence,
a runtime write, and a refusal without a loaded stub are rejected. These
controls execute no emulator and contribute no FEX observation to the table.

The actual aggregate checks complete per-family operation inventories, exact
case/failure counts, expected mutation names, PE hashes and the additional
atomic ticket invariant. SSE2 requires all 236 instruction mismatches plus its
hand vector; a hand-vector failure alone is insufficient. Missing or extra
outcomes, changed runtime artifacts and incomplete per-run metadata fail the
aggregate. An interrupted native-only experiment retained its error and false
FEX completion and left no compiler child running.

All five #104 milestones are complete. This corpus adds only first-party
sources, harnesses and reports. The Wine repair belongs to separate issue #111;
no FEX source changes or shared-runtime writes are part of #104. No hosted CI
job was added. Issue #78 remains open, unassigned, unmodified and separate;
its CAS-tear telemetry was neither read nor changed.
