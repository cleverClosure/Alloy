# ADR-0004: Keep a Thin Wine Fork and Put Differentiation in Providers and Profiles

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** CTO, Wine Lead  
**Related requirements:** RUN-003

## Context

Wine contains decades of Windows user-mode behavior and an active upstream community. A large proprietary fork or rewrite would consume resources on generic compatibility while accumulating rebase risk. Title-specific code inside Wine is difficult to audit and retire.

## Decision

Alloy will maintain a rebasing-friendly Wine fork with stable hooks for process policy, execution providers, graphics/native services, and diagnostics. Generic fixes are upstreamed where practical. Title-specific behavior lives in signed profiles or versioned providers.

## Rationale

This preserves upstream leverage and focuses proprietary engineering on Mac-gaming differentiation. It also makes title workarounds explicit data rather than hidden branches.

## Consequences

### Positive

- Faster access to upstream fixes.
- Lower long-term maintenance.
- Clear open-source/proprietary boundary.
- Better testing and workaround lifecycle.
- Easier security review.

### Negative / cost

- Upstream timelines may not match product needs.
- Stable hooks may require temporary downstream patches.
- Rebase discipline and contributor relationships require investment.
- Some bugs cross provider/Wine boundaries.

## Alternatives considered

1. **Rewrite the Win32 layer:** infeasible and strategically wasteful.
2. **Large permanent fork:** gives control but creates compounding maintenance.
3. **Use upstream unmodified:** may not expose required early policy/provider hooks.

## Validation and implementation notes

Track downstream patch count, age, owner, tests, and upstream status. Demonstrate that a new upstream Wine generation can be evaluated per title without globally changing installed games.

## Revisit triggers

Revisit if upstream architecture makes essential provider hooks impossible, but require a quantified long-term fork cost and alternatives.
