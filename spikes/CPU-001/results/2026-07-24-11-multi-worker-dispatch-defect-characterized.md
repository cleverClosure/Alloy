# CPU-001 result 11 — #24 recharacterized: the multi-worker guest-AV defect is realistic, not synthetic; wedge downgraded to clean termination

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `c5785db` (zero-resume-pc guard) · **FEX:**
`alloy/spike-fex-001` @ `93cae98` · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Why this exists

Result 10 closed the exception-dispatch "deadlock" family and filed the
residual as item #24, framed as a *concurrent-simultaneous* corner: "4 threads
AVing at the same instant behind one event." That framing was wrong in a way
that matters. This note recharacterizes #24 with a new sweep test
(`testcases/seh_multi.c`), corrects the severity upward, isolates the
mechanism, and lands a bounded wine-side mitigation. The functional root
remains FEX-side and founder-owned.

## The severity correction

`seh_multi` sweeps the concurrency shape while holding everything else fixed
(each worker catches its own null-write AV under `__try/__except`,
async-scope-table-built per result 10):

| Mode | Description | Result |
| --- | --- | --- |
| simultaneous | all workers released by one event (== `seh_concurrent`) | 1/4 caught, wedge |
| staggered | worker *i* delayed *i*×15 ms after release | 1/4 caught, wedge |
| **sequential** | **one worker faults at a time, joined turn-by-turn, siblings alive but idle** | **1/4 caught, wedge** |
| warmup | main thread catches first, then sequential workers | main caught, then 1/4, wedge |

**Sequential wedging is the headline.** The defect does *not* need
simultaneity — it reproduces when exactly one thread faults at a time with the
others merely existing. That is the ordinary shape of a multithreaded game
where more than one worker thread catches a hardware fault over the process
lifetime (managed-runtime null-refs, Mono/.NET, per-thread guard-page tricks).
5/5 deterministic. #24 is therefore a realistic pre-title concern for
multi-thread titles, not the synthetic corner result 10 implied.

Reconciling with the green tests: `seh_worker` (main + **one** worker) passes
because there is only one worker; `seh_deep`'s main thread dispatches many
exceptions and passes because **the main thread is never affected**. The
precise boundary: **the main thread and the first worker thread dispatch guest
exceptions correctly; the second and subsequent worker threads wedge.** A
main-thread warmup does not inoculate the workers.

## The mechanism (wine-side trace, per-thread)

For two workers taking the byte-identical fault — same shared-cache JIT block
`pc 0x…255c4`, same write to address 0:

- **Worker 0 (succeeds):** fault → `prepare_exception_arm64ec` packs a valid
  guest Rip (`0x1400018FE`) → `KiUserExceptionDispatcher` → `__except` runs →
  caught.
- **Worker 1 (wedges):** the null-write fault **never reaches
  `prepare_exception_arm64ec`** (no packed-Rip trace). Instead: a zero-pc
  `NtContinue` (`signal_set_full_context` sentinel, `InSimulation=1`) →
  execution at pc 0 → a wild access at `0 − sizeof(ARM64_NT_CONTEXT)`
  (`0xfffffffffffffc70`, i.e. −0x390) → **`handle_syscall_fault` claims that
  secondary fault** because SP is on the syscall stack, and redirects the
  thread to `__wine_syscall_dispatcher_return` with a resume pc taken from a
  syscall frame whose saved pc is **0** → back to pc 0 → infinite re-fault
  loop (300% CPU, or the in-guest watchdog fires exit 8).

So there are two layers: a **root** (worker 1's identical fault is misrouted to
a zero-context continue instead of guest dispatch — FEX-side, upstream of
`prepare_exception`) and an **amplifier** (`handle_syscall_fault` turning the
resulting pc-0 execution into an unbounded loop — wine-side).

## The mitigation (wine, `c5785db`) — amplifier only

`handle_syscall_fault` now refuses to claim an access violation when the
syscall frame's saved return pc is 0 (`sf->pc == 0`, and no `jmp_buf`). A zero
resume pc can never be legitimate — returning to user mode there always
re-faults — so the guard is defensively correct independent of #24. Effect,
verified:

- The **infinite loop is broken**: the process terminates cleanly instead of
  spinning at 300% CPU. **No winedbg cascade** (result 10's orphan-cascade risk
  checked explicitly: zero `winedbg`/`AeDebug` launches on the guarded path).
- **Regression-neutral:** `seh_worker`, `seh_deep`, `exception_unwind`,
  `guard_enforce`, `x64hello`, `memory_semantics` all exit 0 — the guard fires
  only on the already-corrupt `sf->pc==0` state.

What the mitigation does **not** do: make worker 1 *catch*. The `__except` still
never runs; the process now dies cleanly rather than hanging. That is a
failure-mode improvement (hang → clean termination), the same doctrine as
result 10's "an unhandled fault must terminate, never wedge" — not a functional
fix.

## The root (open, FEX-side, founder) → #24 stays open

Worker 1's null-write fault is misrouted before it reaches `ResetToConsistentState`.
Both workers execute the same shared-cache block; the divergence is per-thread
emulator state on the exception entry. Candidate localisation for the next pass
(from the static recon map, corroborated):

- `ProcessPendingCrossProcessEmulatorWork()` runs first on the `SyncThreadContext`
  re-entry path (wine `signal_arm64ec.c:1058`) and before every compile — a
  process-wide cross-thread work drain that could race a second worker's
  dispatch. Instrument around it first.
- `RethrowGuestException` builds the dispatcher frame on the guest stack from
  `GuestSp`; if worker 1's guest stack / `State.rip` is not yet valid at pack
  time, the packed Rip is 0. The pre-null-write read fault at the dispatcher
  gadget (`pc 0x…fc1018`, reading each worker's own high guest-stack address,
  *unresolved* for worker 1) is a candidate trigger.

Attribution is still blocked by the dead FEX-module log channel (result 10);
the wine-side traces here were enough to localise the amplifier but the root
needs FEX-internal visibility. Recommended first step next session: solve the
sink-injection (wine writes a sink pointer into a FEX export slot resolved the
same way the BTCpu64 pointers already are) before touching the FEX dispatch.

## Doctrine reinforced

Third time today a "runtime defect" was mischaracterised by its first
appearance: the deadlock family was a test artifact + cascade (result 10), the
graphics red was a launch-environment mismatch (this morning), and #24's
severity was understated by testing only the simultaneous shape. The fix each
time was the same — vary the input that the first framing held fixed
(`-fasync-exceptions`, the GFX recipe, the concurrency *shape*) before trusting
the conclusion.
