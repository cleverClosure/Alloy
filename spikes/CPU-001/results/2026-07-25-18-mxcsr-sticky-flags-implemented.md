# CPU-001 result 18 — FEX now preserves MXCSR sticky exception-status flags

**Author:** Timur Isaev
**Date:** 25 July 2026
**FEX:** `alloy/task-7-mxcsr` @ `98d5e2d`, on `ce60231` · **Wine:**
`alloy/spike-wine-001` @ `36a24a1` · **Hardware:** M2 Pro, 16 GB,
macOS 26.5

## Outcome

Issue #7 is implemented. FEX now exposes the six cumulative ARM64 FPSR
exception bits as the corresponding x86 MXCSR sticky status bits:

| MXCSR | FPSR |
| --- | --- |
| IE bit 0 — invalid | IOC bit 0 |
| DE bit 1 — denormal input | IDC bit 7 |
| ZE bit 2 — divide by zero | DZC bit 1 |
| OE bit 3 — overflow | OFC bit 2 |
| UE bit 4 — underflow | UFC bit 3 |
| PE bit 5 — precision | IXC bit 4 |

The flags now accumulate across guest FP operations, survive `stmxcsr`, accept
guest-supplied state through `ldmxcsr`, and clear when the guest writes a zero
status field. The required CPU/SEH corpus remains green, 16/16.

## Implementation

The change is confined to FEX's existing MXCSR choke points:

- `GetMXCSR` reads FPSR, permutes its cumulative exception field into MXCSR
  bits 0–5, and combines it with the existing guest control state.
- `RestoreMXCSRState` writes the incoming status field back to FPSR before
  retaining MXCSR control bits 6–15 in the guest context. Bit-field inserts
  preserve unrelated FPSR fields.
- New `GetFPSR` and `SetFPSR` IR operations are side-effecting, preventing
  optimization or reordering across the FP instructions whose status they
  observe.
- The ARM64 JIT emits `mrs FPSR` and `msr FPSR` for those operations.
- XSAVE's MXCSR mask changes from `0xFFC0` to `0xFFFF`, because the complete
  defined field is now supported.

Ordinary FP instructions gain no additional work. FPSR is read or written only
when the guest reads, writes, saves, or restores MXCSR.

## The false negative in the first implementation pass

The first pass appeared to build cleanly but have no runtime effect. Even a
temporary `0xDEAD` constant returned by `GetMXCSR` failed to appear in the
guest, which initially suggested that `stmxcsr` used a different dispatcher
path.

That conclusion was wrong because the instrumented DLL was stale. With
`WINEDLLOVERRIDES=libarm64ecfex=b`, this Wine build loads its builtin from:

```text
spikes/WINE-001/work/build-2/dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll
```

Replacing only the prefix's `windows/system32/libarm64ecfex.dll` did not change
the loaded image. After replacing the build-tree builtin, the `0xDEAD` control
sentinel reached every guest `stmxcsr`. The sentinel was then reverted and the
real implementation immediately produced the expected status flags. Future
runtime validation must synchronize both locations.

## Direct MXCSR verification

Purpose-built probes established both directions independently:

| Operation | MXCSR readback |
| --- | --- |
| Explicit clear, then divide by zero | `0x1F84` — ZE set |
| Explicit clear, then square root of -1 | `0x1F81` — IE set |
| Explicit clear, then overflow | `0x1FA8` — OE and PE set |
| Seed ZE with `ldmxcsr` | `0x1F84` |
| Clear all status bits with `ldmxcsr` | `0x1F80` |

The probes also preserved the existing FTZ/control-bit round trip.

`x87_fp_edge` now makes the behavior a mandatory corpus assertion rather than
an advisory known gap. It:

1. clears all six MXCSR status bits;
2. divides by zero and requires ZE;
3. computes `sqrt(-1)` and requires IE and the earlier ZE together;
4. clears the field again and requires all six bits to read zero; and
5. restores the caller's original MXCSR.

The case builds with `-fno-math-errno` so the invalid operation is emitted as a
guest FP instruction rather than delegated to a C-library path. Its result is:

```text
fp exception values: ok
fp sticky flags accumulate: ok
fp sticky flags clear: ok
cpu-001 x87/fp edge ok
```

## Regression verification

`arm64ecfex` rebuilt successfully from `98d5e2d`. The loaded DLL and the two
synchronized copies had SHA-256:

```text
ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6
```

The issue's 16-test CPU/SEH baseline was rebuilt and passed, every executable
exit 0:

`memory_semantics`, `fault_cost`, `noaccess_inventory`, `jit_pages`,
`isa_smoke`, `x87_fp_edge`, `cpu_throughput`, `cpu_scaling`, `threads_tls`,
`guard_enforce`, `exception_unwind`, `seh_deep`, `seh_concurrent`,
`seh_worker`, `seh_multi`, and `seh_repeat`.

`seh_nullcall` remains the separately tracked known-red case in issue #20 and
is not a member of this baseline. `win_smoke` is the separate GUI-prefix test;
in the current non-interactive macOS session it still exits 3 with the known
degenerate client-height result, so it is not evidence for or against the
CPU-only change.

## Disposition

The done condition is met: sticky exception status is deterministic after an
explicit clear, later exceptions accumulate until the next guest clear, the
corpus enforces the behavior, and all 16 baseline tests stay green.

The FEX commit is AI-assisted under the founder's fork-local exception. It is
recorded in `PROVENANCE-ALLOY.md` and must never be contributed upstream
without independent founder reimplementation. As with the preceding FEX spike
changes, `third_party/src/FEX` is an ignored nested checkout, so `98d5e2d`
lives in the local FEX clone; the Alloy commit carries the enforced corpus
test, result, and provenance record.
