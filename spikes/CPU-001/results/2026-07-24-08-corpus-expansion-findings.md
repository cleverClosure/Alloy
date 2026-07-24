# CPU-001 result 08 — corpus expansion: six families green, exception dispatch is the fragile area

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `87adaaa` + absorb telemetry · **FEX:** darwin-teb build
**Hardware:** M2 Pro, 16 GB, macOS 26.5

## Corpus verdict

| Guest | Families green | Findings |
| --- | --- | --- |
| `x87_fp_edge` | x87 extended precision, rounding modes, denormals, NaN semantics, int64 division edges, bit manipulation | **MXCSR sticky exception flags not virtualized** (`fetestexcept` reads clean after div-by-zero/invalid); **FMA3 not fused** — both `fma()` and the direct `vfmadd` instruction double-round (mask 0x188) |
| `threads_tls` | TLS isolation (`__thread` + TlsAlloc across workers), 400-thread create/join churn, **contended atomics exact** (20000/20000, 64-bit 60000/60000) — exit 0 | — |
| `seh_deep` | 32-deep nested `__finally` unwind in exact innermost-first order; `RaiseException` argument delivery through filters | **AV inside `__try` intermittently wedges dispatch even single-threaded** (2 of 4 runs); **`EXCEPTION_CONTINUE_EXECUTION` with modified Rip never resumes** (reproduced twice before restructure) |
| `seh_concurrent` (detector) | — | **Simultaneous multi-thread guest AVs deadlock exception dispatch reliably** — wedges so completely the in-guest watchdog's `ExitProcess` cannot run; killed by the harness guard both runs |
| `dxc.exe` (real application) | Entire LLVM-based compiler executes exit-0 (result: M12-003) | — |

## The dominant finding: FEX/EC exception dispatch vs threads

Three presentations, one work area:

1. **Reliable deadlock — guest AV while other guest threads exist.** The faulting
   thread's dispatch suspends siblings (SIGUSR1 → `wait_suspend`); the protocol never
   completes. Sampled twice: waiters parked in `server_select`/`wait_suspend`, the
   faulting thread(s) pinned in `segv_handler` (two-fault variant spins at 199% CPU,
   single-fault variant parks silently at ~0%). Samples:
   `logs/threads-livelock.sample.txt`, `logs/threads-v4b.sample.txt`.
2. **Intermittent single-threaded wedge** at a plain caught AV (`seh_deep` AV-address
   family: passed twice, wedged twice, run-order dependent).
3. **Continue-execution hang**: a filter that advances Rip past `ud2` and returns
   `EXCEPTION_CONTINUE_EXECUTION` never resumes the thread.

Games fault with live threads routinely (JIT engines, copy protection, guard pages) —
**this is the top pre-title founder item**, ahead of the 4 KB guard-granularity work.
Everything pointed at "slow atomics" earlier in the day was this deadlock wearing a
costume; the atomics themselves are exact and fast.

## Dispatcher-gadget x18 fault tax (telemetry now permanent)

Rate-limited absorb tracing added to the fork's x18 backstop identified the absorbed
fault sources precisely: runtime-emitted FEX dispatcher gadgets (MAP_JIT region, not
rebuild-able by darwin-teb flags) read `[x18, #0x60]` and `[x18, #0x1788]` after every
kernel entry zeroes x18, plus ntdll's own `[x18, #0x30]` TSD re-materialize. Absorb
counts are low in steady state (8 in the traced run) — a per-kernel-entry tax, not a
storm. Founder fix direction: emit `mrs tpidrro_el0`-based TEB loads in the gadgets
(zero faults, tpidrro is never kernel-zeroed), exactly as the fork's static wrappers
already do.

## Corpus design lessons

- Tests that can hit runtime defects must be **detectors, not casualties**: defect
  families run last, behind in-guest watchdogs *and* harness-level kill guards —
  the concurrent-AV wedge proved in-guest watchdogs alone are not enough.
- One family per failure domain: the original combined guest serialized coverage
  behind its first stall and cost three diagnosis rounds.
- Continue-past-failure with a bitmask exit (x87 guest) yields full family data per
  run; exit codes truncate to 8 bits — keep masks within range.

## Founder FEX/EC fix list after this result (priority order)

1. Exception-dispatch deadlock family (items 1–3 above) — pre-title blocker.
2. 4 KB guard granularity (result 06) — pre-title census item.
3. MXCSR sticky flags + FMA fusion — pre-LAB-001 determinism items.
4. Dispatcher-gadget tpidrro TEB loads — perf polish, telemetry in place.
