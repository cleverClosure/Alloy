# M12-003 result 01 — DXIL→Metal shader path: corpus green, diagnostics proven, dxc runs under Alloy

**Author:** Tim Isaev
**Date:** 24 July 2026
**Hardware:** M2 Pro, 16 GB, macOS 26.5 · **Provenance:** ADR-0012 discipline model,
inputs logged in [PROVENANCE.md](../PROVENANCE.md) — no excluded source consulted.

## Verdict

```text
add_cs / clamp_cs / intops_cs / select_cs / twobuf_cs: GPU matches CPU reference
wave_cs: rejected with named diagnostic (M12003-unsupported: dx.op.waveActiveOp.f32)
corpus: 5 pass, 1 rejected-with-diagnostic, 0 fail
m12-003 shader path ok
```

The doc-16 hypothesis holds at spike scope: a legally clean compiler pipeline from
DXIL to executing Metal code exists, every stage isolated and diagnosable.

## The pipeline (each stage a separate, inspectable artifact)

1. **HLSL → DXIL** with the unmodified NCSA `dxc.exe` (x64, release v1.9.2602.24) —
   **running under Alloy's own Wine/FEX stack, exit 0**. An entire LLVM-based
   compiler is by far the largest real-world x64 binary the runtime has executed;
   this doubles as CPU-path evidence (census: known chunk-tail signature only, more
   instances from the larger translated footprint).
2. **Ingest/validate** (`prototype/dxil_to_msl.py`): original DXBC-container parser —
   magic, size, part table bounds, DXIL part, shader-model tag, SHA-256 of the
   container into the provenance record. Hard errors on malformed containers.
3. **Normalize**: DXC's own textual disassembly (`-Fc`) parsed into a small op list
   covering the defined compute subset — `dx.op.createHandle`, `threadId`,
   `bufferLoad/Store` (f32 and i32), float/int ALU, `dx.op.binary` FMin/FMax, fcmp +
   select. **Anything else fails with a named `M12003-unsupported:` diagnostic** —
   proven by the wave-intrinsic shader, never silent.
4. **Lower to MSL**, compile with the system `metal` toolchain, execute via a generic
   metallib runner; outputs compared against a **CPU interpreter over the same
   normalized IR** (an independent reference, not a re-derivation from MSL).
5. **Determinism + provenance**: lowering runs twice and must be byte-identical;
   per-shader JSON records container/IR/MSL SHA-256 and op counts.

## Findings worth keeping

- **Mainline LLVM cannot read DXIL bitcode.** `llvm-dis` (llvm@15) rejects it
  ("Malformed block") — DXIL froze a pre-3.7 dialect with custom abbreviations, so
  the backward-compat guarantee does not apply. Disassembly stays a DXC-family
  responsibility; the production pipeline should bind `dxcompiler` as a library
  rather than shelling out.
- The DXIL container carries a *second* embedded bitcode module (STAT reflection) —
  naive "find the bitcode magic" grabs the wrong one; parse the part table.
- dxc under Wine/FEX is fast enough to be the corpus generator for all future shader
  work (a compile ≈ seconds including process start).

## Doc-16 pass evidence

| Evidence | Result |
| --- | --- |
| Target corpus pass rate | 5/5 supported shaders GPU-exact vs reference; 2-buffer and integer paths included |
| Deterministic output | double-lowering byte-compare enforced per shader; MSL hashes recorded |
| Compiler isolation and diagnostics | staged artifacts on disk per shader; named-diagnostic rejection proven |
| Licensing/provenance | NCSA dxc as tool only; ADR-0012 log; per-artifact hash records |
| Performance/stutter path | not measured at spike scope — deferred with Phase-1 pipeline-cache design |

## Honest limits

Compute-only; tiny op subset (no waves, derivatives, precision variants, control
flow beyond select); SM 6.0 `createHandle` only (6.6 `createHandleFromBinding`
unhandled); text-parsing front end is a spike expedient — production binds the
DXC library and walks DXIL properly.

## Build & run

`prototype/run_corpus.sh` — drives dxc-under-Wine, lowering, `metal` compile, GPU
execution, and comparison for the whole corpus; exit 0 = green.
