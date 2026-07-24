# SPIKE-M12-003 — DXIL-to-Metal shader path

**Author:** Tim Isaev
**Status:** Active (started 24 July 2026)
**Canonical definition:** [doc 16 §M12-003](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md)
**Provenance:** [ADR-0012 discipline model](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md) · log in [PROVENANCE.md](PROVENANCE.md)

**Hypothesis:** the project can legally and technically build a compiler pipeline for
the required shader-model subset.

## Method

Pipeline at spike scope, every stage isolated and diagnosable:

1. **Produce** DXIL from HLSL with the unmodified NCSA `dxc.exe` (x64) running under
   Alloy's own Wine/FEX stack — the toolchain dogfoods the runtime.
2. **Ingest/validate**: an original DXIL-container parser (FourCC parts, sizes,
   shader-model tag, DXIL part extraction) with hard validation errors.
3. **Normalize**: disassemble the DXIL part with `llvm-dis` (LLVM reads bitcode back
   to 3.0 by compatibility guarantee; DXIL is 3.7-era) and parse the textual IR of a
   defined compute subset — dx.op thread-id, raw/structured buffer load/store, float
   ALU — into a small normalized op list. Unsupported constructs must fail with a
   named diagnostic, never silently.
4. **Lower** the normalized IR to MSL source, compile with the system `metal`
   toolchain, execute on the GPU against CPU-reference outputs.
5. **Determinism**: lower twice, byte-compare MSL and hash the metallib; **provenance
   cache**: record tool identities+hashes per artifact.

Deferred beyond spike scope: wave ops, derivatives, precision variants, graphics
stages, large corpus — the spike proves the path shape, not shader-model coverage.

## Results log

Dated notes in `results/`. Hardware baseline: MacBook Pro M2 Pro, 16 GB, macOS 26.5.
