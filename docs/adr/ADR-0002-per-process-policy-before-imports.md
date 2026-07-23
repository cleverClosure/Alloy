# ADR-0002: Resolve Compatibility Policy Per Process Before Normal Imports

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** Runtime Platform, Wine Team, Security  
**Related requirements:** RUN-002, CMP-002, CMP-008

## Context

A game installation contains heterogeneous processes: launcher, updater, embedded browser, game, anti-cheat bootstrap, configuration tool, crash reporter, and helpers. Bottle-wide graphics/synchronization/DLL settings force incompatible processes to share one behavior. Selecting policy after a process initializes is too late because graphics and runtime DLLs may already be loaded.

## Decision

Alloy will identify every Windows process and compile a policy before normal module initialization. The policy selects CPU, graphics, synchronization, DLL, native-service, filesystem, network, security, and diagnostics behavior. Matching uses exact executable digest and process lineage where available. Unknown processes receive a conservative default.

## Rationale

This directly solves launcher/game backend conflicts, permits narrow workarounds, improves security containment, and makes behavior explainable. Early selection prevents accidental initialization of the wrong provider.

## Consequences

### Positive

- Launcher and game can use different graphics providers.
- Rules are scoped to exact binaries/process roles.
- Unknown helpers do not inherit unrestricted access.
- Workarounds are observable and removable.
- Provider failures are deterministic rather than silent fallback.

### Negative / cost

- Requires stable Wine loader/process-creation hooks.
- Process identification has startup cost and must handle self-updating launchers.
- Policy conflicts and inheritance need rigorous semantics.
- Debugging mixed providers in one process tree is more complex.

## Alternatives considered

1. **Bottle-wide setting:** rejected as too coarse.
2. **Environment variables only:** mutable, difficult to secure, and often too late.
3. **Post-launch DLL injection:** fragile, security-sensitive, and anti-cheat-hostile.
4. **Separate bottle per executable:** breaks shared launcher/game state and still complicates lifecycle.

## Validation and implementation notes

Prototype the loader hook with a launcher using D3D11/DXMT and child game using a D3D12 provider. Verify policy is selected before graphics imports, an unknown child receives a restricted default, and compiled policy is deterministic.

## Revisit triggers

Revisit the exact hook or serialization if upstream Wine offers a better mechanism. Revisit match inputs when storefronts or signed executable metadata provide stronger identity.
