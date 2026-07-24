# CPU-001 result 10 — the exception-dispatch "deadlock" family resolved: a test-build artifact, a real FEX guard bug, and the anatomy of the wedge

**Author:** Tim Isaev
**Date:** 24 July 2026
**FEX:** `alloy/spike-fex-001` @ 635922c + JITGuardPage fix (this note) · **Wine:**
`alloy/spike-wine-001` @ 5a0d3a3 + backstop hardening (this note) · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

Result 08's dominant finding — "FEX/EC exception dispatch vs threads, three
presentations, one work area" — decomposes into **four separate causes**, none
of which is the lock-cycle deadlock it appeared to be. After one test-build fix
and two runtime fixes:

- `seh_worker` (new): caught null-write AV on the **main thread and a worker
  thread** — exit 0.
- `seh_deep`: **all families green including the two named defects** — the
  intermittent single-thread wedge is gone, and `EXCEPTION_CONTINUE_EXECUTION`
  with a filter-modified Rip (skip-`ud2`) **resumes correctly** ("rip skip:
  after=42").
- `exception_unwind`, `guard_enforce`, `x64hello`, `isa_smoke`,
  `memory_semantics`: green, regression-neutral. `x87_fp_edge` unchanged at its
  known MXCSR/FMA mask (founder item #3).
- `seh_concurrent` (4 simultaneous AVs): **no longer wedges the system** — the
  in-guest watchdog now runs and reports; 1/4 catches. The residual 3/4
  corruption is a distinct, charted defect (below, now item #24).

## Cause 1 (dominant): the SEH corpus never contained handlers

`llvm-mingw` clang only anchors `__try` scopes at **call sites**. A `__try`
guarding a bare faulting instruction (`*null_ptr = x`) compiles to **no scope
table entry at all** unless `-Xclang -fasync-exceptions` is passed — silently.
`seh_concurrent.exe`'s `av_worker` had a RuntimeFunction but **no exception
handler**; a probe exe at `-O1` had **no unwind entry whatsoever** (the guarded
function was inlined and the scope dropped). The runtime was then *correct* to
report the exceptions unhandled.

- `seh_deep` mostly worked because its `__try` bodies contain calls
  (`RaiseException`, `printf`, recursion), which anchor the scopes.
- `exception_unwind` passes because its families are VEH/longjmp/callback-based.
- Every corpus SEH test is now built by `testcases/build-corpus.sh`, which
  encodes the required flags; verification: `llvm-readobj --unwind` must show
  `__C_specific_handler` for the guarded functions.

MSVC-built binaries (i.e. real games) emit async-safe scope tables by default —
this artifact affected only our mingw-built corpus, which is exactly why the
"defect" reproduced so reliably here.

## Cause 2 (real FEX bug, fixed): JITGuardPage claims the null page

`Windows/Common/JITGuardPage.h` treats a fault as a JIT temp-buffer overflow if
`Address ∈ [Thread->JITGuardPage, +FEX_GUARD_PAGE_SIZE)`. `JITGuardPage` is
**zero until the thread's first compilation** (threads that only execute
cache-hit blocks never set it), so the check degenerates to
`Address < FEX_GUARD_PAGE_SIZE`: **every null-page dereference on such a thread
was claimed as a guard overflow** and the context replaced from the stale (zero)
restart jump buffer — the thread resumes at pc 0 with sp 0. This is an upstream
latent bug; our host-page guard fix (result 09) merely widened the claim window
4×. Fix: null-check `JITGuardPage` before the range test (fork commit).

The observable signatures this produced (all reproduced, then eliminated):
`NtContinue` to an all-zero CONTEXT_ARM64_FULL context; a wild write at exactly
`0 − sizeof(ARM64_NT_CONTEXT)` (= `-0x390`) inside the continue servicing;
threads dead at pc 0 with the guest Rip still in x9.

## Cause 3 (the actual "deadlock"): the AeDebug cascade

With handlers missing (cause 1), the first-chance exception went unhandled →
wine launched `winedbg --auto` (AeDebug `Auto=0` did **not** suppress launch —
side-finding) → the debugger's attach does `suspend_process`, parking every
sibling in `wait_suspend` (the exact stacks sampled in result 08) → **winedbg,
itself an x64 process under the same runtime, then died** (its own 4 GB-floor
mmap failure + an internal crash) → nobody ever resumed the suspended process.
The "reliable deadlock so complete the watchdog cannot run" was a **suspended
process orphaned by its dead debugger**, not a lock cycle. The 199 %-CPU
variant was the same flow where the faulting threads livelocked re-faulting
instead of parking (cause 4).

## Cause 4 (real wine-fork gap, hardened): the backstop dereferenced the fault pc

`handle_arm64ec_teb_load` read `*(uint32_t*)PC` to decode the faulting
instruction. For a thread resumed at pc 0 (cause 2), that read **nested a fault
inside the SIGSEGV handler** → kernel-speed redelivery livelock (the 300 % CPU,
`segv_handler+448`-pinned threads; lldb: `EXC_BAD_ACCESS address=0x0` at the
decode line). Hardened: the backstop now refuses when the pc is in the null
page or the pc *is* the fault address (execute faults). A rate-limited
`zero-pc continue` sentinel plus fault-class heartbeats (segv entries, resolved
faults, align faults) are kept in the fork so any recurrence is attributable —
the same doctrine as the absorb telemetry.

## Residual open defect → item #24

With everything above fixed, 4 *simultaneous* guest AVs still corrupt 3 of the
4 threads: during their re-entry (suspend doorbells raised by concurrent
dispatch), FEX's reset path continues them with an all-zero packed context
(`State.rip = 0` at pack time — a thread-state lifecycle race, not the
JITGuardPage path). Bounded: the process self-reports via its watchdog (exit
8), no system wedge, no debugger cascade; single-fault and
single-fault-per-thread dispatch is fully green. Repro: `seh_concurrent.exe`;
candidate hardening (doorbell-defer on unentered state, SRA-liveness gating,
`EXCEPTION_BREAKPOINT` acceptance for the brk trap) was prototyped, did not
change the outcome, and is recorded here rather than committed. Attribution
needs FEX-side breadcrumbs; note that **every print channel from the module is
dead under wine** (LogMan sink resolution fails in-module; new `.def` exports
are invisible to wine's native-view lookup), so the next attempt should inject
a wine-side sink pointer through an existing exported slot instead.

## Side-findings

1. `winedbg` under the runtime is broken (4 GB-floor mmap failure, internal
   crash at a fixed address) — any unhandled guest exception currently orphans
   the process instead of producing a backtrace. Pre-title item: disable
   auto-launch properly (AeDebug `Auto=0` string did not) or fix winedbg.
2. `d3d11_draw`/`win_smoke` failed tonight with `D3D11CreateDevice` →
   `80004005` **on stock builds of both forks and in two prefixes** — the exact
   configuration that was pixel-exact this morning. Environmental
   (Metal device creation without an interactive WindowServer session — the
   machine was likely locked); re-verify in an interactive session before
   reading it as a regression.
3. FEX derives wine syscall IDs by sorting `Nt*` exports by RVA
   (`Module.cpp` `InitSyscalls`) — fragile against wine export changes; worth a
   runtime cross-check eventually.

## The lesson

Result 08's family was diagnosed through its *symptoms* (stacks parked in
`wait_suspend`, watchdogs dead). The mechanism only fell out of instrumenting
each hop of one fault's journey — wine-side ERR tracing at the dispatch
boundary, the continue trace at `NtContinueEx`, and lldb against the live
wedge. Detectors detect; only per-hop tracing attributes.
