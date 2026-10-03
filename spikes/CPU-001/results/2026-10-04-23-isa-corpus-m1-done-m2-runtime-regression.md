<!-- Author: Timur Isaev -->

# CPU-001 result 23 — SSE2 native proof passes; the x64 runtime is blocked

**Date:** 4 October 2026  
**Host:** M2 Pro, 16 GB, macOS 27.0 (26A428)  
**FEX source:** `alloy/task-8-dispatcher-teb`,
`ad942313dca79d32133cceaaf617016821e3b952`  
**Wine source:** `alloy/spike-wine-001`, `420c70b`; existing modifications to
`dlls/ntdll/unix/signal_arm64.c` and `dlls/rpcrt4/ndr_stubless.c` were preserved.

## Correction to the original report

The first version attributed the fault storm to an old FEX DLL missing the
result-21 dispatcher fix. That attribution was unsupported. GFX-001
[result 09](../../GFX-001/results/2026-07-26-09-deus-ex-title-scene.md)
records the **exact installed DLL hash** working on macOS 26.5.2 (25F84).
The host has since changed to macOS 27.0. A fresh current-tip DLL also
fault-storms in an isolated Wine clone (§2), so rebuilding FEX alone does
not resolve the observed failure. The operating-system change is the
leading hypothesis; its causal mechanism has not been isolated.

This is tracked separately in [issue #111](https://github.com/cleverClosure/Alloy/issues/111).
Issue #104 milestone 2 remains incomplete: neither its clean FEX pass nor
its deliberately corrupted FEX failure has been observed. A timeout is
never credited as a successful mutation control.

## 1. What the native corpus proves

The corpus contains 50 table-driven SSE2 integer operations and three
immediate-controlled shuffles: 12,736 deterministic cases over edge operands
and seeded random operands. On arm64 it runs portable references only. On
x86-64 it compares those references with SSE2 intrinsics.

Reverified after handover:

| Build | Native exit at O0/O1/O2/O3 | Reference checksum |
| --- | --- | --- |
| Clean | 0 / 0 / 0 / 0 | `21ba41417def5d07` |
| Deliberately corrupted `paddb` | 1 / 1 / 1 / 1 | `eb480915973927bd` |

Each build's complete output matches across all four optimization levels and
across three separate O2 invocations. The mutated build reports `paddb` by
name. `build-corpus.sh` also cross-compiles all 22 Windows test programs.
See [result 24](2026-10-04-24-isa-corpus-native-verification.md) for the
native milestone's repeatable commands and limits.

There are **11 independent hand vectors**, ten table-operation vectors and
one shuffle vector. The other 42 operations have no hand-computed oracle.
Cross-optimization agreement and determinism alone cannot show that those
42 references implement the correct instruction semantics. As an additional
cross-check, an x86-64 Mach-O build at O0 and O2 runs all comparisons under
Rosetta and matches the arm64 reference checksum. This is an independent
translator check, not a FEX result or execution on physical x86 hardware.

The compiler explanation was also corrected: with llvm-mingw first on PATH,
a bare `clang` resolves there, while `xcrun -f clang` resolves to Xcode's
compiler. They are different binaries. The native proof explicitly uses
`/usr/bin/clang`.

## 2. Isolated runtime experiment

Both the FEX source and Wine build-2 were copied with `cp -Rc` into
`spikes/CPU-001/work/runtime-diagnosis/` in the private worktree. All
configuration, compilation, DLL replacement, prefixes and logs stayed there.
The shared source checkouts retained their existing branches and contents.

The fresh DLL was built with the existing Darwin TEB `winnt.h` overlay and
the established build flags: `arm64ec-w64-mingw32`, Release, tests/assertions/
LTO/jemalloc disabled, `TUNE_CPU=none`, `TUNE_ARCH=generic`, bundled fmt,
`-ffixed-x18`, and `FEX_HOST_GUARD_PAGE_SIZE=16384`. Configure and all 226 build
steps completed. No FEX source was edited.

| Input | SHA-256 |
| --- | --- |
| Original DLL, built in July | `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` |
| Fresh current-tip DLL | `8630e1dc9e1a9755a74d61295bb4b90e30eeea7aca62fdb387e767ace57db29c` |
| Wine `ntdll.so`, unchanged in both runs | `f24783b4be0d7c3d8fd8cb69674a125a38a5498735b1077e5209743e0690100d` |
| No-CRT `x64min.exe`, expected exit 42 | `044caeda6bb55954675faf21d57b888176332b425504db22752725ef41293e15` |

Each DLL was installed into the clone's builtin
`dlls/libarm64ecfex/aarch64-windows/` path, with its hash checked. Each run
used a separate fresh prefix and checked `ps` for shared build-2 activity
before every invocation. `wineboot -u` and the Wow64 emulator registration
both exited 0. Module traces show the builtin `libarm64ecfex.dll` loading.

| DLL | `x64min.exe` result | Repeated sampled PC/address |
| --- | --- | --- |
| Original | Timed out at 10 s | `0x102f600e8` |
| Fresh | Timed out at 10 s | `0x1047300f8` |

Both logs repeat `segv_handler` and `resolved-fault` heartbeat messages at
one unchanged address within that run, without reaching the guest's return.
These are sampled diagnostics; this report makes no calibrated fault-count
or fault-rate claim from their frequency. The original handover additionally
recorded the same symptom for `isa_smoke.exe`, fresh prefixes, and both Wine
entry points. Those observations were not needlessly repeated here.

A sorted JSON inventory of shared build-2's regular-file SHA-256 values and
symlink targets contains 18,038 entries. Before and after the experiments,
the inventories are byte-identical, with manifest SHA-256
`b8a757ac0b8aa0658b4c55e069c1f8634707e4b762907a981cf324bd70b6bdd2`.
This proves the shared runtime was preserved. Raw logs, build configuration,
prefixes and the inventories are retained under the private worktree's
`spikes/CPU-001/work/runtime-diagnosis/` directory.

## 3. Review fixes verified and completed

The interrupted review's five planted reference bugs were reproduced in
scratch copies: dropped rounding in `pavgb` and `pavgw`, inverted `pcmpgtb`,
wrong high-half shift in `pmulhw`, and swapped operands in `psubq`. Every
one is rejected by its named hand vector. Removing the hand-vector failure
counter increment also fails the native proof instead of producing a false
pass.

Two further gaps remained in the guest harness:

- The clean guest verdict checked exit code and the reference checksum, but
  ignored explicit `FAIL` lines. The checksum folds reference values, so a
  broken mismatch counter could hide an actual guest/reference disagreement.
- With `--skip-mutate`, the metadata block ended in a false `[[ ... ]] &&`
  condition. Under `set -euo pipefail` it exited before reaching the verdict.

Both are fixed. Shared verdict logic now requires exactly one complete
summary, the native checksum, the expected mutation tag, the expected exit
code, and consistent failure text/count. The clean result refuses any
`FAIL` line. The mutation requires a named `paddb` mismatch and exit 1;
crashes and timeouts fail. `run-isa-corpus.sh --selftest` verifies nine
synthetic outcomes without starting Wine. The skip-mutate metadata path was
also executed under strict shell mode and confirmed to reach the verdict.

These are harness checks. They do not substitute for milestone 2's real
clean/mutation FEX run, which remains blocked by #111. Breadth milestones
3–5 and issue #78 are unchanged.
