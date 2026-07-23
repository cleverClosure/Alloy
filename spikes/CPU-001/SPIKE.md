# SPIKE-CPU-001 — FEX on macOS feasibility

**Author:** Tim Isaev
**Status:** Active (started 23 July 2026)
**Canonical definition:** [doc 16 §3](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md) · decides [ADR-0005](../../docs/adr/ADR-0005-fex-arm64ec-execution-path.md)

**Hypothesis:** A FEX-derived provider can execute representative x64 Windows games under an
ARM64-native Wine/ARM64EC environment with correct exceptions, memory semantics, W^X, and
commercially acceptable CPU overhead — on macOS, which upstream FEX does not support as a host.

## Method (incremental gates)

1. **Build survey** — configure/build FEXCore + unit tests on macOS unmodified; catalogue every
   failure by class (syscall surface, memory model, JIT/W^X, ELF assumptions, thunks, build system).
   The failure catalogue *is* the deliverable of this gate: it sizes the port.
2. **Minimum host abstractions** — port allocator/signal/thread primitives behind a host layer:
   Mach exception ports vs. signals, `MAP_JIT` + per-thread `pthread_jit_write_protect_np` W^X,
   16 KB host pages under 4 KB-page guest expectations (page-size shear is the #1 suspected killer —
   measure, don't assume).
3. **ISA/ABI corpus** — run FEX's instruction-correctness corpus on macOS;
   **must include AVX2/BMI/SSE4.2** (portfolio titles hard-require them: FF VII Rebirth and FF XVI
   boot-gate on AVX2; Yakuza family needs AVX+SSE4.2 — catalog findings §7.0).
4. **Mixed process** — one ARM64EC/x64 process under SPIKE-WINE-001's Wine build.
5. **Representative games** — two portfolio titles, one CPU-bound
   (candidates from D-020 core: Sekiro or Dark Souls III class); deterministic scene; collect
   transitions, exceptions, frame-thread CPU time, code-cache metrics; cache persistence.

## Pass evidence (from doc 16)

No structural blocker in Mach exception/JIT/memory model; conformance target agreed;
representative game reaches deterministic scene; performance gap has an actionable optimization
plan; stable unwind/crash diagnostics; upstream-contribution strategy approved.

**Fallbacks:** alternate translator provider; narrower catalog; macOS-version pinning
(Rosetta games-subset clock: production path must be usable ~fall 2027 — legal findings §1.5).

## Results log

Dated notes in `results/`, newest last. Every measurement names its exact upstream revision
(see `third_party/deps.lock`) and hardware (dev machine: MacBook Pro M2 Pro, 16 GB, macOS 26.5).
