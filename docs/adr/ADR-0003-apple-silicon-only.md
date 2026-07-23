# ADR-0003: Support Apple Silicon Only

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** CEO, CTO, Product  
**Related requirements:** RUN-004

## Context

Supporting Intel and Apple-silicon Macs would duplicate CPU execution, binary packaging, Metal capability, OS, performance, and lab paths. The strategic opportunity is modern Apple GPU/unified-memory optimization and an ARM64-native future after Rosetta becomes constrained.

## Decision

All first-party host components will be ARM64-native. Certified support excludes Intel Macs. Host selection is capability-based across Apple-silicon GPU and memory classes.

## Rationale

The decision concentrates scarce low-level engineering, permits current Metal and macOS assumptions, and removes a declining architecture from the critical path.

## Consequences

### Positive

- Smaller runtime and test matrix.
- Clear FEX/ARM64EC architecture.
- Direct optimization for unified memory and Apple GPUs.
- Fewer legacy OS constraints.
- Simpler support message.

### Negative / cost

- Excludes existing Intel Mac users.
- Some early Wine paths may be easier under x86_64/Rosetta.
- Market size is narrower than “all Macs.”
- Requires production CPU translation sooner.

## Alternatives considered

1. **Universal host:** rejected because it doubles strategic complexity.
2. **Intel-first bootstrap product:** rejected because it creates migration debt and weakens the moat.
3. **Cloud fallback for Intel:** separate product economics and not part of the local runtime.

## Validation and implementation notes

Audit all release binaries for ARM64. Validate minimum representative Mac classes and ensure no hidden x86_64 helper is required.

## Revisit triggers

Only revisit with credible commercial demand that outweighs a separately costed Intel platform and does not delay the Apple-silicon roadmap.
