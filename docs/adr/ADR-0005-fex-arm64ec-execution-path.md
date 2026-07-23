# ADR-0005: Use a FEX-Derived ARM64EC Execution Path

**Status:** Proposed — Phase-0 validation required  
**Date:** 20 July 2026  
**Decision owners:** CTO, CPU Translation Lead, Wine Lead  
**Related requirements:** RUN-004, RUN-005

## Context

Windows games are predominantly x64 while the host is ARM64. Rosetta is useful for prototypes but is controlled by Apple and has a constrained future. Building a new x86 translator from scratch is high risk. Wine ARM64EC enables mixed native ARM64 and translated x64 modules.

## Decision

Define a CPU ExecutionProvider ABI. Target a macOS-adapted FEX-derived provider integrated with Wine ARM64EC as production. Use Rosetta only as an optional bootstrap and performance reference where available and legally/platform permitted.

## Rationale

FEX offers mature translation work to build on while the provider abstraction contains host adaptation. ARM64EC reduces the need to translate native-compatible Wine components and creates a mixed-architecture path.

## Consequences

### Positive

- Avoids strategic Rosetta dependence.
- Reuses existing translator expertise.
- Allows native ARM64 Wine/host components.
- Supports side-by-side provider benchmarking.
- Enables persistent game-specific translation caches.

### Negative / cost

- FEX macOS adaptation may be substantial.
- ARM64EC/Wine integration is complex.
- Exception, memory, W^X, self-modifying code, SIMD, and performance correctness are high risk.
- Upstream licensing/contribution and maintainership require care.

## Alternatives considered

1. **Rosetta production foundation:** rejected strategically.
2. **New translator:** rejected unless FEX has a proven unfixable limitation.
3. **Full Windows ARM VM with x64 emulation:** heavier and outside the product thesis.
4. **Native-only publisher port:** unavailable for arbitrary existing builds.

## Validation and implementation notes

Phase-0 tests must cover representative x64 games, ARM64EC boundaries, exceptions/unwind, atomics, self-modifying code, JIT W^X, persistent cache, and CPU-bound frame performance. A formal go/no-go date is mandatory.

## Revisit triggers

Reject or revise if Phase-0 evidence shows unacceptable correctness/performance or an infeasible macOS port. The provider abstraction remains even if the implementation changes.
