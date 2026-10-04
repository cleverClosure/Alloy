# CPU-001 result 29 — SSE2 FEX milestone verified

Author: Timur Isaev

Issue #104 milestone 2 now passes through the isolated Wine runtime repaired
by issue #111. The shared `build-2` was not rebuilt or replaced. Its original x64 runtime
still lacks that repair. The selected private runtime is read-only during this
harness run; only a fresh prefix, guest binaries and evidence are written under
this worktree's `spikes/CPU-001/work/`.

## Observed outcomes

| Check | Exit | Cases / failures | Checksum / evidence |
| --- | ---: | --- | --- |
| Native reference | 0 | 12,736 / 0 | `21ba41417def5d07` |
| Native corrupted reference | 1 | 12,736 / 1 hand-vector mismatch | `eb480915973927bd` |
| Unregistered x64 control | 1 | Wine's actual builtin `xtajit64.dll` refuses execution | `x64 emulation not implemented`; FEX not loaded |
| FEX clean SSE2 | 0 | 12,736 / 0 | `21ba41417def5d07` |
| FEX corrupted SSE2 | 1 | 12,736 / 237 named `paddb` mismatches | `eb480915973927bd` |

Both guest outcomes contain actual `trace:loaddll:build_module` builtin FEX load
events. A DLL lookup, nonzero exit, timeout, or silent zero counter cannot satisfy
the verdict. All nine existing verdict self-tests also pass.

The runner now creates a unique evidence directory instead of deleting a prior
run, bounds diagnostic volume and child-process lifetime, and checks both the
selected and shared runtimes for contention immediately before each invocation.
Each invocation records the exact Wine/FEX source revisions and four runtime
binary hashes. A failed `ps` check refuses execution. Cleanup targets only this
prefix's server and accepts `wineserver -k`'s documented already-exited result
while still rejecting a timeout. Complete runtime inventories are compared on
success and on error.

## Identities and preservation

- Host: M2 Pro, macOS 27.0 (26A428), 16 KiB host pages.
- Wine source: clean private `alloy/task-111-macos27-runtime`,
  `f0937d595166631dd00eaab31fef4fb5a6f37031`.
- FEX source: clean private copy at
  `ad942313dca79d32133cceaaf617016821e3b952`; no FEX source change.
- Selected runtime:
  `/private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/wine-build`.
- `loader/wine`: `d77a3f35bc0941b43226cb0f761f811051b33a057b79ab1f4324e4a29404a0dd`.
- `server/wineserver`: `7cf50a002813624d7a7cbbdd13f0fc1205844b4603a81b77c919503e159bb728`.
- Repaired `dlls/ntdll/ntdll.so`: `815e465b80dca0802770a3ae36471af344ee1cae0c280d93d3b1308abbac8a89`.
- Actual builtin FEX DLL: `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6`.
- Selected runtime's 21,652 directory/file/link entries, names, modes and content:
  before = after = `8f0fa54a52cdd63ac7eb8fb722f210a375649e96fbd0cfadaf727423c7fa763a`.
- Shared runtime's corresponding full inventory remains
  `00640da69a959497db45a5da2ee1086392b2e9faa7337448f835e3313ce7ce0d`.
  Shared Wine's two inherited diagnostic edits are byte-identical to the
  pre-repair diff; shared FEX is clean on its original branch.

Raw evidence is in
`/private/tmp/alloy-104/spikes/CPU-001/work/isa-corpus/run.9Gj3Ix/`:
`runtime-before.json`, `runtime-after.json`, per-invocation `logs/*.metadata.json`,
complete guest logs and `run-metadata.txt`. The wrapper's successful output is
`/private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/m2-final-3.log`.

## Reproduction

From this milestone checkout, select the already-built private runtime explicitly:

```sh
ALLOY_WINE_BUILD=/private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/wine-build \
ALLOY_WINE_SOURCE=/private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/wine-source \
ALLOY_FEX_SOURCE=/private/tmp/alloy-111/spikes/CPU-001/work/runtime-111/fex-source \
  bash spikes/CPU-001/run-isa-corpus.sh
```

The default command requires both clean and mutated outcomes. `--skip-mutate` is
a development check and cannot establish milestone completion. Later milestones
replace this single-family entry point with the complete aggregate target. No CI
job was added. #78 remains separate and untouched.
