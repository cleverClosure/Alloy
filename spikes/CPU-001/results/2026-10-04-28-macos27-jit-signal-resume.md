# CPU-001 result 28 — x64 execution restored on macOS 27

Author: Timur Isaev

Issue #111 is repaired in an isolated Wine build. `x64min.exe` returns 42,
`isa_smoke.exe` passes, and #104's clean SSE2 corpus passes while its named
mutation is rejected. The existing FEX DLL is unchanged. The source fix is the
reviewable [Wine patch](../../WINE-001/jit-signal/wine.patch), with a
[native regression proof and application instructions](../../WINE-001/jit-signal/README.md).
No shared runtime has been replaced.

## Cause and distinguishing controls

Wine relied on enabling MAP_JIT execution inside the fault handler and retrying
the interrupted instruction. On this M2 Pro running macOS 27.0 (26A428), that
transition does not survive the original signal return. A minimal native program
reproduced the repeated execute fault without Wine, FEX or a Windows prefix.
Enabling execution before the call succeeds; so do an ordinary system call and
a signal delivered while the thread is already in execute mode.

The committed native proof bounds the old path at four repeated faults. Its
replacement completes after one fault and one fresh signal. This isolates the
broken Wine assumption on the current host. The corresponding native experiment
was not run on macOS 26, so this report does not claim a measured kernel-version
comparison. Earlier diagnosis also rebuilt current-tip FEX and reproduced the
failure, ruling out an old DLL as the demonstrated explanation.

The repair saves the full interrupted context in preallocated thread state,
returns normally to native code on a guarded private stack, enables execution
with the public pthread API, then uses a fresh SIGUSR2 to restore the saved
registers and signal state. Both signal returns use the system's normal path.
Existing Wine context restoration and guest memory-protection checks remain in
place. No FEX source change is needed.

A same-toolchain A/B test rebuilt the pre-fix Wine code in this same private
build directory. Its registered `x64min.exe` run still timed out after ten
seconds, with the actual builtin FEX loaded. Applying the Wine fix restores the
expected result. Both cases used private prefixes; this is not an inference from
rebuilding a different FEX DLL or changing a prefix copy of the emulator.

## Verification

| Check | Observed outcome |
| --- | --- |
| Native direct-execution control | Zero faults, all state checks pass |
| Native old-handler control | Four repeated faults, deliberately bounded |
| Native repaired transition | One fault and one complete restore |
| Originally blocked SIGUSR2 | Original signal mask restored; passes |
| Nested alternate-stack signal | Resumes correctly; stack state restored |
| Eight native threads, 64 iterations each | 512 faults and 512 restores; zero mismatches |
| Corrupted saved x9 / v15 | Each exits 1 and names only its corrupted state check |
| Rebuilt pre-fix Wine + original FEX | `x64min.exe` times out at ten seconds |
| Final Wine fix + same FEX | `x64min.exe` exits 42; `isa_smoke.exe` exits 0 |
| Clean FEX SSE2 | 12,736 cases, zero failures, `21ba41417def5d07`, exit 0 |
| Corrupted FEX SSE2 | 237 named `paddb` failures, `eb480915973927bd`, exit 1 |
| Complete #104 ISA corpus | 13 clean families, 13 named mutations and the atomic ticket control pass their expected verdicts |
| Existing cross-view JIT fixture | All six modes pass: positive, RX target, RX after RWX, decommitted target, decommitted crossing, non-temporal store |

The native assembly fixture checks 30 GPRs, all 32 SIMD registers, SP, NZCV,
FPCR/FPSR and the entire 128-byte red zone. Darwin's reserved x18 is preserved as
captured in the signal context but excluded from the platform-level preservation
assertion. The patch's actual header is extracted and compiled for these tests;
the runner rejects divergence from the separately reviewable header.

All final x64 guest runs assert an actual builtin FEX load event, exact expected
exit status and a finite deadline. The cross-view rejection cases catch and
validate guest access violations; a hang or arbitrary nonzero exit cannot pass.
The native proof is registered as a full-tier suite. The fast tier retains its
23 entries and no hosted job has been added.

## Exact identities

| Artifact | SHA-256 / git revision |
| --- | --- |
| Wine fork base | `420c70bdcb7615c3dc0395d162f93645f098fe56` |
| Clean repaired Wine source | `f0937d595166631dd00eaab31fef4fb5a6f37031` |
| Unchanged FEX source | `ad942313dca79d32133cceaaf617016821e3b952` |
| Installable Wine patch | `da99584650e1c0a9fe38a31608558f0cd9980968bec63adf0b22437080b48c0f` |
| Native bridge header | `a1e76d4f38f56d102a165107a09c379206ba7aa832a2a513272193e5b0bad973` |
| Copied Wine loader | `d77a3f35bc0941b43226cb0f761f811051b33a057b79ab1f4324e4a29404a0dd` |
| Copied wineserver | `7cf50a002813624d7a7cbbdd13f0fc1205844b4603a81b77c919503e159bb728` |
| Original shared ntdll | `f24783b4be0d7c3d8fd8cb69674a125a38a5498735b1077e5209743e0690100d` |
| Pre-fix ntdll rebuilt with current compiler | `5b51a6f581596f76563b41d39464242507b7beb1b5a973dc70c9422583c29cf2` |
| Final repaired ntdll | `815e465b80dca0802770a3ae36471af344ee1cae0c280d93d3b1308abbac8a89` |
| Actual unchanged builtin FEX DLL | `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` |
| Six-byte x64 minimum guest | `044caeda6bb55954675faf21d57b888176332b425504db22752725ef41293e15` |

Only ntdll was rebuilt. The rest of the runtime came from an APFS copy of
`build-2`. The copied source's inherited timing and RPC diagnostics were saved,
then excluded from the final clean Wine commit and patch. The originals remain
unchanged in the shared source tree.

The selected runtime's complete 21,652-entry before/after inventory is identical:
`8f0fa54a52cdd63ac7eb8fb722f210a375649e96fbd0cfadaf727423c7fa763a`.
The shared runtime's corresponding inventory remains
`00640da69a959497db45a5da2ee1086392b2e9faa7337448f835e3313ce7ce0d`.
These inventories include directory and file names, modes, symlink targets and
regular-file contents. Shared Wine remains on `alloy/spike-wine-001`; its
pre-existing diff is byte-identical. Shared FEX remains clean on
`alloy/task-8-dispatcher-teb`.

## Evidence and limits

The verified private runtime and clean source copies are under
`/private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/`:

- `wine-build/`, `wine-source/`, `fex-source/` are the selected runtime and source identities.
- `probe-_2ewp84m/report.json` and its x64 log record the rebuilt baseline timeout.
- `extra-rpec5_vd/report.json` records final x64 minimum, ISA smoke and six protection regressions.
- `shared-preservation.json` and `shared-after.json` record shared-tree preservation.
- `preexisting-wine.patch` preserves the inherited diagnostic edits.
- The final native report is `spikes/WINE-001/work/jit-signal-runs/run-5why6e_7/report.json` in this worktree.
- The final SSE2 harness evidence is `/private/tmp/alloy-104/spikes/CPU-001/work/isa-corpus/run.9Gj3Ix/`.
- The final 13-family report is `/private/tmp/alloy-104-m5/spikes/CPU-001/work/isa-corpus-runs/run-i5v8lx3u/aggregate.json`: all 27 required FEX outcomes pass and the full runtime inventory is unchanged.

Discarded experimental prefixes were removed when the disk filled; their guest
binaries, logs, reports and compressed registry files were retained. The final
acceptance evidence above completed successfully after space was recovered.

The bridge reserves SIGSTKSZ plus three host pages per thread and adds one
SIGUSR2 round trip per implicit JIT execute transition. This is a correctness
repair, not a performance result. Shared-runtime installation, title testing
and issue #78's separate FEX telemetry work are outside this repair.
