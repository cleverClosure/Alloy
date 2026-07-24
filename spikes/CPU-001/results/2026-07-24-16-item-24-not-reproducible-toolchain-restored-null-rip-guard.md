# CPU-001 result 16 — item #24 does not reproduce once the spike toolchain is repaired: the multi-worker guest-AV wedge is gone at HEAD, a null-RIP dispatch refusal lands FEX-side, and a new charted red (null function-pointer calls are never dispatched)

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `36a24a1` (rebuilt this session) · **FEX:**
`alloy/spike-fex-001` @ `71d19ad` (log sink) + `6f8268f` (null-RIP guard), on `93cae98` · **Hardware:** M2 Pro,
16 GB, macOS 26.5

## Outcome

Issue #6 asked to root-cause and fix the FEX-side wedge where a 2nd+ worker
thread catching a guest AV deadlocks exception dispatch (result 11). The
honest outcome is different from the one the issue anticipated:

- **The spike toolchain was broken end-to-end** and had to be repaired before
  any measurement was possible. Three independent breakages, none related to
  the defect (§1). This is almost certainly why the task stalled.
- **Once repaired, item #24 does not reproduce.** 63 runs across the full
  corpus, every concurrency shape, both FEX builds, logging on and off, plus a
  new 800-fault repeated-AV stress in three shapes: all green, zero wedges
  (§3). The failure signature is *positively* absent, not merely unobserved:
  all four workers now pack the same valid guest RIP that result 11 saw only
  from its one succeeding worker (§3.3).
- **The root cause was not identified.** Five candidate explanations were
  tested and eliminated (§4). A defect that cannot be reproduced cannot be
  root-caused, and this note does not pretend otherwise.
- **A FEX-side guard landed anyway** (§5): dispatch now refuses a packed guest
  RIP of zero, which is the state result 11 recorded and the one that turns a
  caught AV into an unbounded pc-0 re-fault loop. It is the FEX-side mirror of
  the already-accepted wine-side `sf->pc == 0` refusal.
- **A new, unrelated red was found and charted** (§6): a guest calling through
  a null function pointer is never dispatched to its handler at all. This
  reproduces identically on the pre-task FEX build, so it is pre-existing, not
  a regression — but it is game-relevant and needs its own issue.

## 1. The toolchain was broken — three unrelated breakages

The repository was renamed `macgaming` → `Alloy`. Nothing in the spike's build
trees survives that, because they all bake absolute paths:

1. **Every FEX build directory pointed at the pre-rename source path.**
   CMake stores `CMAKE_HOME_DIRECTORY` absolutely; the recorded source tree no
   longer existed, so no FEX build could run. The stale worktree at the old
   path is also still registered in `git worktree list` as prunable.
2. **The Wine build tree was broken in two ways.** 83 `nls/*.nls` symlinks
   pointed at the old path (`wineserver: failed to load l_intl.nls`, so nothing
   ran at all), and `Makefile`/`config.status` carried ~664k stale absolute
   paths, so Wine could not rebuild either.
3. **Host environment drift since the last session.** Homebrew Python is now
   3.14, which no longer provides `pkg_resources`; FEX's
   `Scripts/aarch64_fit_native.py` therefore crashes and leaves
   `string(STRIP ${AARCH64_CPU})` with no argument, failing configure. A
   Homebrew `fmt` also appeared on the host, and `find_package(fmt QUIET)`
   matches that **native macOS** library during an `arm64ec-w64-mingw32`
   cross-configure, failing generate with `IMPORTED_IMPLIB not set`.

Repairs (all in `spikes/*/work/`, none committed):

- Fresh FEX build dir `spikes/CPU-001/work/build-task6`, configured against the
  Alloy path. The exact recipe is recovered from the old `CMakeCache.txt`,
  which is the authoritative record of the prior configure — including
  `TUNE_CPU=none`, the flag that skips the broken Python probes entirely.
  Add `-DCMAKE_DISABLE_FIND_PACKAGE_fmt=TRUE` to force FEX's bundled `fmt`.
- Wine `nls` symlinks repointed; `Makefile` and `config.status` path-rewritten.
  `make` now reports `ntdll.dll` up to date, confirming the built Wine matches
  its source at HEAD.

**Standing lesson:** an absolute-path build tree does not survive a repo
rename, and the failure presents as unrelated compiler/loader errors. When a
build directory refuses to work after a move, read its `CMakeCache.txt` /
`config.status` first — they record the original invocation and are the fastest
route back to a working configure.

## 2. What is actually running

Established rather than assumed, because result 11's conclusions depend on it:

- Wine tree clean at `36a24a1`; `dlls/ntdll/aarch64-windows/ntdll.dll` rebuilt
  and reported up to date by `make`. It contains both the log-sink installer
  (`FEXWineLogSink`) and the amplifier guard string
  (`refusing syscall-fault claim with zero resume pc`), so `c5785db` and
  `36a24a1` are genuinely in the running binary.
- The prefix's own `system32/ntdll.dll` does **not** contain the log sink,
  which confirms the build-tree PE ntdll is what loads.
- The FEX log-sink bridge works: FEX breadcrumbs reach stderr under Wine. This
  is the channel result 10 recorded as dead and result 11 named as the blocker
  for attribution. It is now live, and every trace in this note depends on it.

## 3. Item #24 does not reproduce

### 3.1 Coverage

All green, `exit 0`, with the task-6 FEX build:

| Test | Shapes | Result |
| --- | --- | --- |
| `seh_multi` | simultaneous, staggered, sequential, warmup | 4/4 caught, every shape, 3 rounds |
| `seh_concurrent` | 4 simultaneous AVs | caught, 3 rounds — previously *excluded by design* |
| `seh_repeat` (new) | hammer, sequential, churn | **800/800 caught**, every shape, 3 rounds |
| plain corpus (11 tests) | — | green, 3 rounds |

That is 63 runs with zero wedges, zero watchdog stalls, zero
`zero-pc continue` / `refusing syscall-fault claim` sentinels from Wine, and
zero null-RIP refusals from the new FEX guard across 10,302 guest-exception
dispatches.

### 3.2 `seh_repeat` — the axis the corpus was missing

Issue #6 requires 2+ workers catching AVs **repeatedly**; every existing test
faults exactly once per worker. `testcases/seh_repeat.c` holds the shape fixed
and sweeps repetition instead: `hammer` (all workers looping concurrently),
`sequential` (one worker at a time, round-robin, all alive), and `churn`
(worker threads created and joined repeatedly, so dispatch keeps meeting thread
states created *after* a sibling already dispatched). Write and read faults
alternate so dispatch cannot settle into one cached path. 800 caught AVs per
mode, deterministic.

### 3.3 The signature is positively absent

Result 11's mechanism was specific: worker 0 packs a valid guest Rip
(`0x1400018FE`) and catches; worker 1's fault never reaches
`prepare_exception_arm64ec`, packs Rip 0, and wedges. With breadcrumbs live,
`seh_multi sequential` now shows **four distinct worker threads** each reaching
`Rethrowing onto guest stack`, each packing **`rip=1400018FE`** — every worker
behaves exactly like result 11's single succeeding one. This is what
distinguishes "the defect is gone" from "we did not happen to hit it".

## 4. What was eliminated, and what remains unexplained

Each of these was tested by varying that one factor and re-running:

| Hypothesis | Test | Verdict |
| --- | --- | --- |
| Logging perturbs timing (the sink now works, so the fault path got slower) | `FEX_SILENTLOG=1`, `WINEDEBUG=-all` | Eliminated — green either way |
| The new FEX build differs meaningfully | Ran the pre-task `build-arm64ec-darwin-teb` DLL | Eliminated — green |
| Wine `f24425c` (EC entry-point/TLS-callback redirection) fixed it | Reverted, rebuilt ntdll, re-ran | Eliminated — still green without it |
| Wine `0dfe17e` (ARM64EC x18/TEB contract) fixed it | Reverted PE side, rebuilt ntdll, re-ran | Eliminated — still green without it |
| Result 11 measured handler-less guest binaries (result 10 cause 1, plausible because result 13 later found `build-corpus.sh` had never built the corpus correctly) | Rebuilt `seh_multi` without `-fasync-exceptions` | Eliminated — that produces a *different* signature: immediate death, exit 84, no output |
| The prior session used a different Wine loader (`loader/wine`, not `tools/wine/wine`) | Ran both | Eliminated — green with both |

**What remains unexplained.** No single change accounts for the disappearance.
The strongest surviving hypothesis is that result 11 measured a Wine PE
`ntdll.dll` that was stale relative to its own source tree — the PE ntdll was
rebuilt at 19:26, after result 11's 18:36 measurement, while committing the log
sink — but this could not be confirmed, because the two dispatch-relevant
commits it would have been missing were both individually eliminated above.
Recorded as unresolved rather than guessed at.

**Consequence for the issue.** #24's severity was assessed as "the single most
game-relevant defect left". On this evidence it is not currently reproducible
on any shape, including the realistic sequential one that drove the severity
upgrade. It should be closed as not-reproducible-at-HEAD with the regression
tests retained, not carried as a P0 blocker — and reopened immediately if
`seh_repeat` or `seh_multi` ever goes red.

## 5. The FEX-side change: refuse a null-RIP guest dispatch

`RethrowGuestException` now returns whether the packed guest state is fit to
dispatch, and refuses when the packed RIP is zero:

```cpp
const bool NullExecuteFault = Rec.ExceptionCode == EXCEPTION_ACCESS_VIOLATION && Rec.NumberParameters >= 2 &&
                              Rec.ExceptionInformation[0] == 8 && Rec.ExceptionInformation[1] == 0;
if (!Args->Context.Pc && !NullExecuteFault) { /* log attributable state, refuse */ }
```

Rationale. A zero packed RIP hands the guest a `KiUserExceptionDispatcher`
frame it can never resume from; the return to pc 0 re-faults forever, which is
precisely the item #24 wedge. Refusing routes the exception into the
*pre-existing* pass-through path, so an unresumable state terminates the
process with an attributable message instead of hanging it — the same doctrine
as result 10's "an unhandled fault must terminate, never wedge", and the exact
FEX-side mirror of Wine's accepted `sf->pc == 0` refusal in
`handle_syscall_fault`.

The carve-out matters: a guest that genuinely branches into the null page
*should* carry RIP 0, and that case arrives as an instruction-fetch access
violation at address 0 (`ExceptionInformation[0] == 8`). Refusing it would
break the common "call through an uninitialised vtable or import" crash that
titles catch themselves. The carve-out is currently unreachable because of §6,
but it is required for correctness the moment §6 is fixed.

**Verification status, stated precisely.** The non-firing path is verified: the
guard never fired across 10,302 dispatches and the full corpus stayed green
with it in. The firing path is **not** verified in vivo — an in-process fault
injection was attempted and abandoned (the injected flag would not take effect
through FEX's in-module CRT). The residual risk is small and bounded: the
refusal branch logs and returns `false`, which is the same control flow the
long-standing `Passing through exception` branch already uses.

## 6. New charted red — null function-pointer calls are never dispatched

`testcases/seh_nullcall.c` (new) calls through a null function pointer inside
`__try/__except`, on the main thread and on workers, repeatedly. It was written
to protect §5's carve-out; it instead surfaced a separate defect.

Under FEX the guest handler never runs. The fault arrives with host pc 0, which
is neither in the JIT code buffer nor a dispatcher address, so FEX takes its
long-standing pass-through branch (`Passing through exception`), and Wine then
cannot dispatch it either:

```text
err:seh:segv_handler fault at low pc 0x0 ... type 8 esr_ec 0x20
D 24 Passing through exception
err:seh:call_seh_handlers invalid frame 7ffeddf60008 (0000000105EF8000-0000000105FF0000)
err:seh:NtRaiseException Exception frame is not in stack limits => unable to dispatch exception.
```

Process dies, exit 5. **This is pre-existing, not a regression:** the
pre-task-6 FEX DLL fails identically, and the new null-RIP guard does not fire
(0 refusals). It is charted here, excluded from the green set exactly as
`seh_concurrent`/`seh_multi` were in result 13, and needs its own issue —
calling through an uninitialised vtable or import is an ordinary, frequently
caught game crash.

## 7. Changed files

- FEX fork (`alloy/spike-fex-001`, fork-local, never upstream — the checkout is
  not committed to this repo, so these live in the local clone only):
  - `71d19ad` — the Wine log-sink bridge built to `FEX-LOG-SINK-HANDOFF.md`'s
    spec (`FEXWineLogSink` data export + logging preference, file fallback
    retained). Kept free of dispatch changes, as that handoff requires.
  - `6f8268f` — the null-RIP guest-dispatch refusal (§5).
  - `PROVENANCE-ALLOY.md` records both as AI-assisted and upstream-ineligible.
- `spikes/CPU-001/testcases/seh_repeat.c` (new), `seh_nullcall.c` (new),
  `build-corpus.sh` (builds both; 18 tests).

## Doctrine reinforced

Sixth time in this spike that a "runtime defect" was mischaracterised by the
one variable its first framing held fixed. Result 10: the build flags. Result
13: the build script. Here: **the build environment itself.** The first two
hours of this task produced no information about exception dispatch at all,
because nothing could be built or run — and the resulting errors (a missing
Python module, a mismatched `fmt`, a missing `.nls` file) all pointed away from
the actual cause, a directory rename. Before trusting *or* doubting a prior
measurement, re-establish that the thing being measured still builds and runs.
