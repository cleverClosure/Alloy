# CPU-001 result 23 — ISA corpus Milestone 1 is green; Milestone 2 is blocked because build-2 predates result 21's own fix, and every x64 guest now fault-storms

**Author:** Tim Isaev
**Date:** 4 October 2026
**FEX source:** `alloy/task-8-dispatcher-teb` @ `ad94231` (clean) · **Wine source:**
`alloy/spike-wine-001` @ `420c70b` (dirty: `dlls/ntdll/unix/signal_arm64.c`,
`dlls/rpcrt4/ndr_stubless.c` — both read, neither touched, see §4) ·
**build-2 as actually run:** `libarm64ecfex.dll` SHA-256
`ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` (byte-identical
before and after this session) · **Hardware:** M2 Pro, 16 GB, **macOS 27.0
(26A428)** — every prior CPU-001 result recorded macOS 26.5/26.5.2; see §4.

## Outcome

Issue #104 asks for Milestone 1 (oracle method and generator skeleton, native
side only) then Milestone 2 (the first real run through FEX). Milestone 1 is
done and green. Milestone 2's script is written and its non-FEX setup is
verified, but the FEX run itself cannot complete: **any x64 guest at all —
not just this corpus — now enters an unbounded fault storm through build-2**,
and §3 traces that to a specific, already-identified cause outside this
issue's scope to fix.

## 1. Milestone 1 — the oracle, the generator, and the two mutation controls

`testcases/isa_corpus_sse2.c` is one source, built two ways, the same pattern
`cpu_throughput.c` established: as the x64 Windows guest (reference vs. the
real instruction), and natively for this arm64 host (reference only — there
is no real SSE2 to compare against on this CPU, so the native build instead
checks the reference against itself). 50 table-driven SSE2 integer ops
(wraparound/saturating add and sub, compares, variable-count shifts,
multiplies, pack/unpack, min/max, average, SAD, movemask) plus three
immediate-controlled shuffles (pshufd/pshuflw/pshufhi), each run over a fixed
6×6 edge-pattern cross product and 200 xorshift64-seeded random cases.

`testcases/build-isa-corpus-native.sh` is the native-side proof, run twice
(clean, and with `-DALLOY_CORPUS_MUTATE_PADDB`):

```text
$ build-isa-corpus-native.sh out
run -O0: exit=0
run -O1: exit=0
run -O2: exit=0
run -O3: exit=0
agrees across -O0/-O1/-O2/-O3
byte-identical across 3 separate invocations
cpu-001 isa-corpus sse2: cases=12736 failures=0 checksum=21ba41417def5d07 mutate=none

$ build-isa-corpus-native.sh out -DALLOY_CORPUS_MUTATE_PADDB
run -O0: exit=1
run -O1: exit=1
run -O2: exit=1
run -O3: exit=1
agrees across -O0/-O1/-O2/-O3
byte-identical across 3 separate invocations
cpu-001 isa-corpus sse2: cases=12736 failures=1 checksum=eb480915973927bd mutate=paddb
FAIL hand-vector paddb      expected=00000000000000000000000000000000 got=01010101010101010101010101010101 (0xff + 0x01 wraps to 0x00 in every byte lane)
```

Every Milestone-1 done-criterion is satisfied and independently checked, not
assumed:

- **Reproducible**: the same -O2 binary run three times produces byte-identical
  stdout (`shasum` matched across all three).
- **Self-consistent**: -O0 through -O3 produce byte-identical output — ruling
  out the specific failure mode (a comparison reading something undefined)
  that a fixed seed alone cannot catch.
- **Hand-truth, not self-reference**: five scalar hand vectors and one
  shuffle hand vector are arithmetic written out in the source comment
  (e.g. "0xff + 0x01 wraps to 0x00"), not derived from anything the program
  computes, so a corrupted reference has an independent witness against it
  even with no real x86 instruction on this host to compare against.
- **The corpus can fail, and names what failed**: `-DALLOY_CORPUS_MUTATE_PADDB`
  breaks exactly one reference function (`ref_paddb`, by a constant +1) and
  the hand-vector check catches it by name, on every optimisation level,
  with a diverged checksum, before a single random case even runs.
- **Builds clean via `build-corpus.sh`**: added as `isa_corpus_sse2`, no
  flags needed (SSE2 is the x86-64 baseline); full corpus build (now 22
  guests) still completes clean.

One real toolchain hazard, found and fixed in-flight: `build-isa-corpus-native.sh`
originally resolved `clang` by a bare PATH lookup. Once the mingw cross
toolchain is ahead of Apple's on `PATH` — which lint and the guest build both
require — a bare `clang` (and `xcrun -f clang`, which resolves to the same
toolchain-internal binary) silently compiles for this host but has no macOS
SDK auto-detection, so it fails on the very first system header with no hint
the compiler itself is the problem. Fixed by hardcoding `/usr/bin/clang`;
verified both failure modes before relying on it.

## 2. Milestone 2's script, and what of it is actually proven

`run-isa-corpus.sh` builds the clean and mutate guests, builds the native
oracle, creates a private prefix under `spikes/CPU-001/work/isa-corpus/`
(gitignored), and is designed to produce both outcomes the milestone needs in
one run. The parts that do not depend on the guest actually executing SSE2
code **ran correctly and are verified**:

- `wineboot -u` with `WINEDLLOVERRIDES="mscoree,mshtml="` creates the prefix
  without ever stopping to offer a Gecko/Mono download.
- **The setup's own negative control passed**: run before the Wow64 key is
  written, the exact guest this issue cares about is refused with
  `0024:err:xtajit:ExitToX64 x64 emulation not implemented` — proving the
  registration step is load-bearing, not assumed to be (it took one real
  mistake to get the `WINEDEBUG` channel right: `-all` suppresses *all*
  classes including `err`, so the probe initially found nothing to grep for
  until `+xtajit` was added explicitly).
- `regedit` against `HKLM\Software\Microsoft\Wow64\amd64` succeeds.
- Both wine entry points this build ships (`build-2/loader/wine` and the
  `build-2/wine` → `tools/wine/wine` symlink) launch a process.

What is **not** proven, because it cannot run at all right now: the actual
SSE2 oracle comparison through FEX. See §3.

Every `run-isa-corpus.sh` invocation in this session left build-2 unmodified.
A full recursive content hash of the entire 9.9 GB / 17,944-file tree
(`find . -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256`,
~100 s each way) was taken immediately before the first run and again after
the last: `e1275ba26985aca0bcae46bb1f3532160fb936d51e4b49953ff1ff7e94cbda88`
both times.

## 3. The blocker: build-2 predates its own already-merged fix

Launching *any* x64 guest through build-2 right now — including
`isa_smoke.exe`, which result 04 already proved works, and `x64min.exe`, the
minimal possible PE executable with no CRT at all — hangs. `perl -e 'alarm
shift; exec @ARGV'` kills it at the timeout (exit 142) having produced no
program output at all, after burning the full wall-clock budget at ~90–100%
CPU. This reproduces identically in a brand-new, independently-created
prefix (`/tmp/fresh-pfx-test`, nothing to do with this corpus's own prefix or
setup), with both wine entry points, with timeouts up to 300 s.

`sample(1)` on the hung process shows 87% of samples in `_sigtramp` →
`segv_handler` (`ntdll.so`, `signal_arm64.c`) → `clock_gettime_nsec_np`.
Running with `WINEDEBUG=err` names it exactly — the existing rate-limited
heartbeat counter (first-N-then-every-100,000th, the same shape CLAUDE.md
warns every counter in this tree has had) reached **4.5 million** in 15
seconds, every single one at the identical `pc`/`addr`:

```text
0024:err:seh:segv_handler segv heartbeat #4500000 status 00000000 addr 0x1086f00e8 pc 0x1086f00e8
0024:err:seh:segv_handler resolved-fault heartbeat #4500000 addr 0x1086f00e8 pc 0x1086f00e8
```

"Resolved" every time, at the same address every time — this is not result
19's bounded, attributed absorb cost; it is a fault that never actually lets
the guest make forward progress.

**This result and §18 already named the mechanism.** Result 18 recorded that
this exact installed `libarm64ecfex.dll` — SHA-256
`ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6`, still the
exact file build-2 runs today — was built from FEX `98d5e2d`. Result 21,
*four FEX commits later*, fixed precisely this class of fault: FEX had two
copies of the ARM64EC dispatch preamble, one in `Module.S` (converted
earlier) and one emitted at runtime by `Dispatcher.cpp`/`MiscOps.cpp`/
`Arm64Emitter.cpp` — the second copy kept reading the TEB through x18 without
the fix, and converting it took one entitled title's absorb count from
**over 400,000 to 8**.

```text
$ git -C third_party/src/fex merge-base --is-ancestor 98d5e2d 5944be0 && echo yes
yes
$ git -C third_party/src/fex log --oneline 98d5e2d..5944be0
5944be0 ARM64EC: source generated TEB loads from the Darwin TSD   <- result 21's fix
658630b PROVENANCE-ALLOY: record the issue #20 null-call branch
ff1a395 ARM64EC: report RIP 0 for a guest branch into the null page
86c8130 ARM64EC: dispatch guest branches through a null pointer to the guest
$ git -C third_party/src/fex merge-base --is-ancestor 5944be0 HEAD && echo yes
yes
```

The FEX **source checkout** is at `ad94231`, five commits past `98d5e2d` and
including `5944be0`. **build-2's compiled `libarm64ecfex.dll` was never
rebuilt past `98d5e2d`** — it is missing a fix that already exists, is
already merged into the branch this spike is supposed to be built from, and
was already measured (result 21) to take the exact failure class observed
here from "over 400,000 absorbs, 6.9 ms" to "8 absorbs, ~70 µs". Without it,
every guest that ever asks for the TEB through FEX's generated dispatch
preamble — which is unconditional, not something this corpus's code controls
— faults at a rate high enough to consume the entire timeout budget without
ever reaching `main()`'s first `printf`.

This is not a defect in the oracle, the generator, or `run-isa-corpus.sh`; it
reproduces identically with guests that predate this issue by months. It is
not something this task is scoped to fix: issue #104 explicitly scopes
build-2 as read-only ("no rebuild of Wine or FEX is needed at all"), and the
ground rules forbid writing to it or to `third_party/src/*`. Per this task's
own contingency ("if milestone 2 cannot be completed ... stop ... and report
exactly what blocked it"), that is what this result does.

## 4. Ruled out

- **Not this corpus's code.** `isa_smoke.exe` (unmodified, proven in result
  04) and `x64min.exe` (no CRT) show the identical signature.
- **Not this corpus's prefix.** Reproduces in a prefix created from scratch
  outside `spikes/CPU-001/work/` entirely.
- **Not the wine binary chosen.** Both `build-2/loader/wine` and
  `build-2/wine` (→ `tools/wine/wine`) show it.
- **Not the two dirty files in `third_party/src/wine`.** Read, not touched;
  diffed them directly. `dlls/ntdll/unix/signal_arm64.c`'s only change is
  additive timing telemetry around the *existing* absorb handler
  (`clock_gettime_nsec_np` before/after, for a future cost report — issue #8's
  own pattern, not a behavior change); `dlls/rpcrt4/ndr_stubless.c`'s is an
  `ERR`-logged stack dump gated on one specific RPC procedure number this
  corpus never calls. Neither is a plausible cause and neither was built into
  build-2 regardless (build-2's `ntdll.so` predates both edits' mtimes being
  meaningful, and more to the point build-2 is a separate, un-rebuilt
  artifact from this dirty checkout either way).
- **Build-2 itself is unmodified** — the before/after whole-tree hash in §2
  is the proof, not an assumption.

**Not ruled out, and worth a founder's attention separately from #104**: every
prior CPU-001 result recorded the dev machine as macOS 26.5 or 26.5.2; this
session's machine reports **macOS 27.0 (26A428)**. Result 04 already
documented that macOS's x18-register-clearing behavior across kernel entries
is the specific, fragile thing FEX/Wine's ARM64EC path works around on this
platform. Whether a macOS point/major upgrade changed that behavior's
frequency enough to turn a now-rare (8-per-boot) absorb into one that fires
millions of times a second is plausible and consistent with everything
observed here, but it was not isolated from the stale-build explanation
(§3 is sufficient on its own and did not require it) and this result does not
claim it as proven.

## 5. What this leaves not covered

- The actual FEX-side correctness claim this corpus exists to make — that
  real SSE2 instructions translated by FEX agree with the native-arm64
  reference checksum (`21ba41417def5d07`) — is **unverified**, because no
  guest can currently execute to completion through build-2 at all. The
  guest binary builds clean and the harness is ready; nothing about this
  result should be read as a statement about FEX's SSE2 correctness itself.
- Whether the macOS 26.5→27.0 change independently contributes is unmeasured
  and not claimed either way (§4).
- Breadth beyond SSE2 (#104's later milestones) is untouched, as scoped.

## Recommendation

Rebuilding build-2 from current FEX (`ad94231` or later; must include
`5944be0`) and Wine (`alloy/spike-wine-001` current tip) should resolve the
fault storm, matching result 21's own measurement. That rebuild is out of
scope for a single-corpus milestone and touches shared, contended state
(`build-2`) — it is a founder/scheduling call, not a code change this issue's
scope covers. Once done, Milestone 2 as written in `run-isa-corpus.sh` should
run unmodified; no part of this blocker required changing the script or the
corpus.
