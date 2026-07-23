# ADR-0006: Own D3D12-to-Metal and Reuse a Metal-Native D3D10/11 Provider

**Status:** Accepted strategic direction  
**Date:** 20 July 2026  
**Decision owners:** CTO, Graphics Lead  
**Related requirements:** RUN-007, RUN-008, RUN-010

## Context

Modern game compatibility depends heavily on graphics translation. A D3D12-to-Vulkan-to-Metal chain compounds semantic gaps. Depending permanently on an opaque external D3D12 translator limits roadmap and diagnostics. Rebuilding both D3D11 and D3D12 simultaneously delays product validation.

## Decision

Use and contribute to a maintained Metal-native D3D10/11 provider such as DXMT for the initial catalog. Build a first-party Metal12 D3D12-to-Metal implementation designed around Apple GPU queues, argument buffers, heaps, unified memory, Metal synchronization, shader compilation, PSO caches, and presentation. Bootstrap providers may be used only under explicit legal and architectural constraints.

## Rationale

This balances time-to-market with ownership of the highest-value strategic layer. D3D11 generates early product evidence; Metal12 creates long-term control and moat.

## Consequences

### Positive

- Earlier viable catalog.
- Direct Apple-specific optimization.
- Independent D3D12 diagnostics and release cadence.
- No required Vulkan intermediary for D3D12.
- Title capability masks and precise fixes.

### Negative / cost

- Metal12 is a large multi-year compiler/runtime effort.
- Two graphics codebases need expertise.
- Bootstrap-to-owned migration requires per-title certification.
- Advanced features may remain title/host gated.

## Constraint update (July 2026)

SPIKE-LEGAL-001 found that Apple's GPTK EULA limits distribution of the Apple Software (including D3DMetal) to non-commercial purposes; a commercial product cannot bundle a GPTK/D3DMetal bootstrap D3D12 path. Bootstrap providers under this ADR are therefore lab/reference-only — internal correctness comparison and developer testing — not a shippable interim distribution path. This removes bootstrap D3D12 as a commercial fallback, strengthens the case for the D3D11-first MVP (ADR-0011), and raises Metal12's strategic weight as the only commercially shippable D3D12 path. See [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md) §2, §5–§6 and [ADR-0012](ADR-0012-metal12-provenance-and-clean-room.md).

## Alternatives considered

1. **Use a third-party D3D12 translator indefinitely:** faster but weak control and moat.
2. **D3D12 through Vulkan/MoltenVK:** broader reuse but adds semantic/performance layers.
3. **Build D3D11 and D3D12 from zero:** delays validation.
4. **Publisher-native ports only:** not a general compatibility product.

## Validation and implementation notes

Metal12 vertical slices must independently prove API front end, shader conversion, descriptor lifetime, memory/aliasing, barrier correctness, queue/fence semantics, PSO caching, frame pacing, long-session memory, and real games. Migration is title-by-title through signed profiles.

## Revisit triggers

Review feature subset and staffing after each vertical slice. Revisit reuse choices if a provider’s license, quality, or maintenance is incompatible, not the strategic need to own the D3D12 control point.
