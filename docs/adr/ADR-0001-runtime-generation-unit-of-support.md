# ADR-0001: Use the Game Runtime Generation as the Unit of Support

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** CTO, Runtime Platform, Product  
**Related requirements:** RUN-001, INS-002, INS-007, CMP-001

## Context

Wine-based products commonly expose a mutable prefix or bottle. That environment accumulates installed dependencies, registry state, overrides, launcher updates, caches, and experiments. A support report then describes a state that cannot be reconstructed reliably. A global Wine/provider update may change unrelated games.

## Decision

Alloy will support and certify an immutable **runtime generation** bound to an exact game/launcher build and host class. Runtime layers are content-addressed and read-only. Saves, settings, game payload, derived caches, and session scratch are separate named volumes. Updates create a new generation; activation is atomic; rollback changes the active reference.

## Rationale

This provides deterministic identity, independent per-game pinning, safe rollback, content deduplication, exact lab reproduction, and auditable release provenance. It converts compatibility from mutable installation state into a versioned product artifact.

## Consequences

### Positive

- Exact support and certification identity.
- One game update cannot silently alter another.
- Failed candidates are contained.
- Shared layers reduce storage.
- Support bundles can recreate state.
- Saves are outside disposable runtime state.

### Negative / cost

- More metadata, storage accounting, and lifecycle complexity.
- Some launchers expect to mutate a Windows environment; writable compatibility state must be explicitly modeled.
- Multiple retained generations consume storage.
- Migration from ad hoc prefixes requires import logic or is unsupported.

## Alternatives considered

1. **One global prefix:** rejected because it maximizes cross-title coupling.
2. **One mutable prefix per game:** better isolation but still not reproducible or safe to upgrade.
3. **Full VM snapshots:** stronger isolation but heavier, Windows-dependent, and inconsistent with the product thesis.
4. **Containers without immutable release identity:** insufficient unless exact components and writable volumes are explicit.

## Validation and implementation notes

Implement a CAS/materializer prototype. Demonstrate two games sharing layers, one title upgrading independently, injected failure during activation, automatic rollback, and byte-identical save preservation. Record a LaunchSpecification and recreate it on a second Mac.

## Revisit triggers

Revisit materialization technology if APFS behavior or storage cost is unacceptable. Do not revisit the immutable support-unit principle without a replacement that preserves exact identity, rollback, and save separation.
