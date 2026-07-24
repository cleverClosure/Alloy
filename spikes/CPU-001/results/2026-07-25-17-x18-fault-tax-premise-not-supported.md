# CPU-001 result 17 — the x18 dispatcher-gadget fault tax is not what #8 assumed: the gadgets never faulted, the residual is ~250 faults per *process* (not per crossing), and throughput is unchanged

**Author:** Tim Isaev
**Date:** 25 July 2026
**FEX:** `alloy/spike-fex-001` @ `ce60231`, on `93cae98` · **Wine:**
`alloy/spike-wine-001` @ `36a24a1` · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

Issue #8 asked to remove a per-boundary-crossing fault tax caused by FEX's
dispatcher gadgets reading the TEB through x18, which Apple reserves. The
gadgets were rewritten as asked. The measurement does not support the premise:

- **The dispatcher gadgets were never faulting.** Rewriting all five x18-relative
  TEB loads in `Source/Windows/ARM64EC/Module.S` to source the TEB from
  `tpidrro_el0` changed the absorbed-fault count **not at all** (§2).
- **The residual tax is ~250 faults per process lifetime, not per crossing** —
  a fixed startup-shaped cost, not a hot-path one (§2).
- **Throughput is unchanged within noise** across all four `cpu_throughput`
  workloads (§3).
- **The change is kept anyway, as robustness rather than performance** (§4): it
  removes an undocumented dependency on Wine having established x18 before every
  entry into FEX.
- **#8's "fault counters at ~0" is not met** and cannot be met by the described
  fix, because the sites that actually fault are not the ones it names (§5).

## 1. What was changed

`Module.S` had five x18-relative TEB loads, all in the ARM64EC dispatcher
gadgets: one `TEB->PEB` read in `check_target_ec`, and four
`TEB->ChpeV2CpuAreaInfo` reads in `enter_jit`, `BeginSimulation` (×2) and
`ExitFunctionEC`. Each now goes through a `LOAD_TEB` macro:

```text
.macro LOAD_TEB reg
  mrs \reg, tpidrro_el0
  ldr \reg, [\reg, #0x30]
.endm
```

This is the sequence the Alloy Wine fork already uses in its own dispatch
wrappers (`0dfe17e`), copied rather than reinvented. It is **wrong on real
Windows-on-ARM**, where x18 *is* the TEB, so the file carries that warning; the
fork is macOS-only and never upstreamed.

## 2. The measurement — and why the first attempt was worthless

Wine's absorb telemetry is **rate-limited**:

```text
if (n < 8 || !(n % 100000))
    ERR( "x18 backstop absorb #%u pc %p instr %08x offset %#x\n", ... );
```

So counting log lines reports **8** for any run with fewer than 100,000
absorbs — which is exactly what a naive before/after comparison produced, on
both sides, and would have been read as "no faults, nothing to fix" or "no
change" with equal confidence. The counter was temporarily retuned to log every
absorb (reverted afterwards; the wine tree is clean at `36a24a1`) to get real
numbers:

| Test | Before (x18) | After (tpidrro) |
| --- | --- | --- |
| `isa_smoke` | 247 | 247 |
| `cpu_throughput` | 279 | 277 |

**Unchanged.** Two independent facts explain it:

1. **The gadgets do not fault.** Wine's `0dfe17e` wrappers set x18 from the TSD
   *before* branching to any FEX entry point, so by the time `enter_jit` or
   `ExitFunctionEC` runs, x18 is already valid. The gadget loads were correct by
   accident of Wine's preamble — which is precisely the coupling §4 removes.
2. **The faulting sites are elsewhere.** All absorbs come from four fixed
   instructions, identical before and after:

   ```text
   instr f940324a  offset 0x60     ldr x10, [x18, #0x60]     TEB->PEB
   instr f94bc64b  offset 0x1788   ldr x11, [x18, #0x1788]   TEB->ChpeV2CpuAreaInfo
   instr f94bc648  offset 0x1788   ldr x8,  [x18, #0x1788]   TEB->ChpeV2CpuAreaInfo
   ```

   They use **x8/x10/x11**, not the x16/x17 the gadgets use, so they are not
   `Module.S`. They are also not FEX's C++: the `darwin-teb-overlay` `winnt.h`
   already redefines `NtCurrentTeb()` for `__arm64ec__` to
   `mrs tpidrro_el0; ldr [.., #0x30]`, so compiler-generated TEB reads in the FEX
   module do not use x18. **Their origin is not yet identified** — the four
   addresses sit at a fixed +0x124/+0x284/+0x2f0/+0x33c from a base that matches
   none of the guest modules FEX logs, and chasing it further was out of
   proportion to a P2.

## 3. Throughput

`cpu_throughput`, same machine, back to back:

| Workload | Before | After |
| --- | --- | --- |
| `int_mix` | 3.292 ns/op · 303.79 Mops/s | 3.301 ns/op · 302.89 Mops/s |
| `fp_mac` | 8.168 ns/op · 122.42 Mops/s | 8.161 ns/op · 122.53 Mops/s |
| `mem_stream` | 1.909 ns/op · 523.91 Mops/s | 1.845 ns/op · 542.13 Mops/s |
| `branch_dep` | 5.002 ns/op · 199.93 Mops/s | 5.017 ns/op · 199.33 Mops/s |

All within run-to-run noise, in both directions. Checksums identical, so the
workloads are byte-for-byte equivalent. This is the expected result once §2
establishes the gadgets were not faulting: there was no tax on this path to
remove.

Note the scale even if every absorb were eliminated: ~250 faults over a whole
process, against ~10^8 emulated operations per `cpu_throughput` workload.

## 4. Why the change is kept

It buys robustness, not speed, and should be described that way:

- FEX's gadgets currently work **only because Wine sets x18 first**. That
  contract is real but undocumented on the FEX side, and a Wine-side change to
  the entry wrappers would silently reintroduce faults — or worse, wild reads if
  x18 held something stale rather than zero.
- Sourcing the TEB from the TSD makes each gadget self-sufficient and matches
  what the rest of the macOS port already does.
- It is regression-free: the full corpus is green with it in (14 plain-prefix
  tests, `seh_multi` ×4 shapes, `seh_repeat` ×3 shapes).

## 5. Disposition for #8

**Done-when is not met and cannot be met as written.** "Gadgets no longer fault
on x18" is satisfied only vacuously — they never did. "Telemetry shows fault
counters at ~0" is not satisfied: the count is unchanged at ~250/process,
because the fix does not touch the sites responsible. "Perf delta recorded" is
satisfied, and the delta is zero.

Recommended: close #8 as **premise not supported**, keeping the gadget change as
a robustness fix, and open a separate issue only if the ~250 per-process
absorbs ever look material. They currently are not — the residual is roughly
0.00025% of one `cpu_throughput` workload's operation count, paid once.

The one thing worth carrying forward is the measurement lesson, not the fix.

## Doctrine reinforced

Seventh time in this spike that the first framing held the wrong variable
fixed — and the first time the *instrument* was the thing that lied. Rate-limited
telemetry read as a count is not a count: it reported "8" identically for a run
with 247 faults and a run with 247 faults, and would have reported "8" for a run
with 90,000. The fix was to make the instrument report the quantity being
claimed before trusting any comparison drawn from it. Result 13 corrected a
stale build script; result 16 corrected a stale build environment; this one
corrects a stale *measurement*.
