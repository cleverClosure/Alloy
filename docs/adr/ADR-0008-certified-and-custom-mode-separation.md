# ADR-0008: Separate Certified Mode from Custom Mode

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** Product, Security, Runtime Platform  
**Related requirements:** CMP-009, UX-007, SEC-008

## Context

Advanced users want mods and overrides, while support and anti-cheat partners need a controlled runtime identity. Allowing arbitrary changes inside certified state makes evidence meaningless and creates unsafe support instructions.

## Decision

Certified and Custom Mode use separate state, integrity identity, UI, and launch paths. Custom state may be based on a certified generation but cannot mutate it. Returning to Certified re-verifies or rematerializes trusted state while preserving saves according to policy.

## Rationale

The decision preserves user freedom without sacrificing support truth, rollback, or partner integrity.

## Consequences

### Positive

- Clear support boundary.
- Safe experimentation and reset.
- Stronger anti-cheat/publisher trust.
- Reproducible certified reports.
- Mods cannot silently contaminate a certified generation.

### Negative / cost

- More storage and UX complexity.
- Some game content paths are storefront-mutable and difficult to classify.
- Users may dislike loss of support in Custom Mode.
- Mod compatibility becomes a separate product surface.

## Alternatives considered

1. **Allow edits in place:** rejected.
2. **Prohibit all customization:** harms enthusiast adoption.
3. **Best-effort detection after launch:** too late and forgeable.

## Validation and implementation notes

Test modification attempts, custom clone/reset, save-sharing policy, profile signature, runtime object verification, and user comprehension. A vendor-integrity prototype must distinguish states.

## Revisit triggers

Revisit which modifications may be allowed within a future vendor-approved integrity scope, never the need for explicit state separation.
