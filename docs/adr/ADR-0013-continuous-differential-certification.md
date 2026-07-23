# ADR-0013: Continuous Differential Certification Against Physical Reference Fleets

**Status:** Accepted
**Date:** 23 July 2026
**Author:** Tim Isaev
**Decision owners:** CEO/CTO (founder), Compatibility/Quality
**Related requirements:** CMP-004, CMP-005, DIA-010, NFR-OPS-002

## Context

The v1.0 architecture document carried this decision only in an embedded mini-register that duplicated (and collided with) the canonical ADR directory; the 2026-07-23 consolidation removed that register. The decision itself is load-bearing and is acted on throughout the architecture (§21 compatibility laboratory), the test strategy (doc 08), and the roadmap's lab workstream (doc 11), but was never recorded as a standalone, revisitable decision.

## Decision

Physical Mac reference fleets and physical Windows reference machines, exercised by continuous differential certification runs, are part of the **product architecture** — not optional QA tooling. Certified status is backed by current evidence from real hardware comparing Mac behavior against a Windows oracle; profiles alone, community reports, or one-time manual test passes do not sustain certification.

Fleet scale follows catalog scale: the principle binds from the first certified title (which requires at least one representative certified-floor Mac and one Windows reference machine), and the matrix grows only with evidence-based host-class needs (CMP-010, NFR-EVO-004).

## Rationale

Compatibility inputs change continuously (game, launcher, macOS, runtime components); a static snapshot of evidence decays silently. The Windows reference oracle is what turns "it behaves oddly on Mac" into an attributable defect class. The resulting evidence graph is one of the strategy's four moat layers.

## Consequences

### Positive

- Certification claims remain true over time, not just at award.
- Regressions are attributed by differential comparison rather than guesswork.
- The evidence graph compounds into a durable data/operations moat.

### Negative / cost

- Real hardware capital and refresh cost, automation investment, and storefront/test-account operations from day one.
- Lab throughput becomes a scaling constraint (tracked as R-013) and a real cost driver (R-027); per-title lab cost must be modeled before catalog growth commitments.

## Alternatives considered

1. **Static profiles plus community reports:** rejected — reproduces the anecdotal support model the product exists to replace.
2. **Cloud-only Mac capacity:** partial at best — gaming correctness needs physical GPUs, displays, controllers, audio devices, and thermal behavior; cloud capacity may supplement but not replace the physical matrix.
3. **Windows-reference-free certification:** rejected — without an oracle, behavioral and visual differences cannot be classified as defects with confidence.

## Validation and implementation notes

SPIKE-LAB-001 validates the mechanism (deterministic scene, exact artifact identity, comparable evidence, measured run cost). The per-title lab cost model it produces feeds the catalog-growth and pricing decisions.

## Revisit triggers

Revisit fleet scope if per-title lab cost makes the catalog plan uneconomic (R-026/R-027 triggers), or if a supplemental cloud-Mac tier proves equivalent for defined evidence classes. The principle — certification is continuously earned on real hardware against a reference oracle — is not revisited without replacing the product's core support promise.
