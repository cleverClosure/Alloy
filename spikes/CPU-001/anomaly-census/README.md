# CPU anomaly census controls

Author: Timur Isaev

Issue #78 takes the retirement outcome. **The four CAS-tear flags are not
eligible evidence for a clean-run claim.** This applies to `16bit CAS Tear`,
`32bit CAS Tear`, `64bit CAS Tear`, and `128bit CAS Tear`, even when every
reported value is zero. Raw nonzero values remain visible in the report for
investigation; neither a missing value nor zero proves absence of tearing.

The replacement is a narrower, calibrated set of observations: exact Wine
access-violation and alignment-fault totals, supported split-operation flags,
and FEX's invalid/unimplemented decoder buckets. **These observations cannot
detect every silent partial atomic write.** No result from this harness
certifies general atomicity or a fault-free runtime. `calibration_verdict=PASS`
means the controls and evidence reader passed, including deliberate faults.
The report always carries `cas_tearing.absence_proven=false` and the coverage gap.

## Why retire the flags

The audited FEX source is `alloy/task-37-anomaly-telemetry` at `77f9ae5`.
In `FEXCore/Source/Utils/ArchHelpers/Arm64.cpp`, all four setters are reached
only after a first constituent CAS succeeds and a second CAS fails:

| Flag | Constituent stores | Setter line at this revision |
| --- | --- | ---: |
| 16-bit | two 8-bit CAS operations | 679 |
| 32-bit | two 32-bit CAS operations | 965 |
| 64-bit | two 64-bit CAS operations | 1199 |
| 128-bit | two 64-bit CAS operations | 426 |

Crossing a boundary alone does not force the intervening competing write.
An uncontended split-CAS guest therefore cannot calibrate this event, and a
racing stress loop would not be a deterministic positive control. This does
**not** assert that tears are impossible or the setters unreachable. A future
re-admission would require a deterministic guest control and its matching
negative, including proof that the reported flag is sampled after the event.
Setting a telemetry variable directly would test the reporter, not that path.

## Standing verification

Use an isolated census Wine build with the macOS JIT repair, and the unmodified
FEX revision above. The shared live FEX branch is a different revision and does
not contain this census. Supply all three private paths explicitly:

```sh
python3 spikes/CPU-001/anomaly-census/run.py \
  --wine-build "$private_wine_build" \
  --wine-source "$private_wine_source" \
  --fex-source "$private_fex_source"
```

The runner builds five separate control executables and the existing
`telemetry_probe`. Separate decoder binaries prevent a reachability walk from
counting an unused positive mode in the negative control. The invalid stub is
`06 c3` (PUSH ES is invalid in long mode); the unimplemented-bucket stub is
`f0 90 c3` (illegal LOCK NOP). That bucket's name is a FEX decoder classification,
not a claim that valid NOP instructions are unsupported.

Nine cases must pass:

| Control | Expected guest result and census evidence |
| --- | --- |
| Access-violation negative | 0 caught; no increase from the pre-loop fault snapshot |
| Access-violation positive | 64 caught; exact increase of 64 access violations |
| Decoder negative | Valid NOP/RET returns; both outcome buckets remain zero |
| Decoder invalid | One caught illegal instruction; exactly one invalid outcome at the allocated stub address |
| Decoder unimplemented | One caught illegal instruction; exactly one unimplemented outcome |
| Aligned atomic negative | Exit 0; zero alignment faults and no calibrated split flags |
| Split locked add / 32-bit CAS / 64-bit CAS | Each exits 0; exactly 2,000 alignment faults and both split flags set to 1 |

Both dump intervals are 1 for this calibration. The decoder emits a snapshot
after each decode, including the deliberate rejection; the Wine census emits
complete snapshots and an exit snapshot. Sparse interval dumps sampled before
the operation cannot pass. These settings are for controls, not performance
measurement. Split flags are happened-at-least-once values, never frequencies.

Every guest has a finite deadline and output limit. Its actual builtin FEX
load must belong to the guest process, and Wine fault snapshots are filtered
to that process. Complete snapshots must satisfy both conservation checks:
`segv-entries = resolved + access-violations` for the counted ordinary fault
path, and `total_decode_calls = decoded + outcome buckets` for these
single-thread controls. Alignment, x18-backstop and translated-store paths have
separate counters; the first identity does not count all host signals.

The reader must reject 12 corruptions of the actual recorded evidence:
missing/truncated census, absent builtin load, wrong fault counter, missing
split flag, each lost decoder outcome, absent telemetry baseline, stale decoder
samples, another process's fault census, timeout, and nonzero exit.

Evidence is written to a fresh `spikes/CPU-001/work/anomaly-census-runs/run-*`.
The report binds logs, guests, compiler, test inputs, selected source revisions
and diffs, and runtime artifacts by hash. Full runtime inventories must be
identical before and after execution. It creates and stops only its own prefix,
and checks for active shared-runtime processes before every invocation.

```sh
python3 spikes/CPU-001/anomaly-census/run.py --replay "$saved_run_directory"
```

Replay checks the saved logs and repeats the reader mutations without executing
a guest. Hashes provide local evidence integrity, not independent attestation
that a binary was produced by a particular compiler or source tree.

## Rebuild the private calibration runtime

Start with fresh private APFS copies of the permitted local FEX/Wine sources,
the frozen `spikes/CPU-001/work/census/wine2` build, and
`spikes/CPU-001/work/darwin-teb-overlay`. Preserve inherited source diffs before
selecting revisions in those private copies. Never reset, switch, or build the
shared trees. No upstream fetch or excluded implementation source is needed.

- FEX: select `77f9ae5` on a private `alloy/*` branch; retain its populated
  dependencies. No FEX source edits or new FEX commits are required.
- Wine: select `619c4c0` in the private copy and apply
  `wine-census-resume.patch`. It combines #111's existing JIT repair with the
  census includes, and counts the handled `STATUS_RETRY` path as resolved
  before returning. The JIT bridge header is unchanged from #111.

With absolute private paths and the primary pinned LLVM-MinGW toolchain on
`PATH`, configure FEX as follows. The source include overlay and 16 KiB guards
are required by this Darwin build; LTO must be disabled for this toolchain.

```sh
cmake -S "$private_fex_source" -B "$private_fex_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$private_fex_source/Data/CMake/toolchain_mingw.cmake" \
  -DMINGW_TRIPLE=arm64ec-w64-mingw32 -DBUILD_TESTING=OFF \
  -DTUNE_CPU=none -DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE \
  -DENABLE_CCACHE=OFF -DENABLE_LTO=OFF -DENABLE_ASSERTIONS=OFF \
  -DENABLE_OFFLINE_TELEMETRY=ON \
  -DCMAKE_C_FLAGS=-ffixed-x18 -DCMAKE_CXX_FLAGS=-ffixed-x18 \
  "-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -I$private_overlay -DFEX_HOST_GUARD_PAGE_SIZE=16384" \
  "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -I$private_overlay -DFEX_HOST_GUARD_PAGE_SIZE=16384"
cmake --build "$private_fex_build" --target arm64ecfex --parallel 2
```

Reconfigure the copied Wine build with its private source using #111's
[instructions](../../WINE-001/jit-signal/README.md#applying-the-fork-patch-in-isolation),
then build only `dlls/ntdll/ntdll.so`. Install the new FEX DLL into the private
build's `dlls/libarm64ecfex/aarch64-windows/` directory. Confirm that target is
not a symlink into a shared tree. A prefix system32 copy does not select FEX.

This is a calibration runtime based on historical census branches, not a
replacement for the live runtime or an instruction to promote those branches.
