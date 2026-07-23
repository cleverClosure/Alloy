# ADR-0007: Store Runtime Components in a Content-Addressed Immutable Object Store

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** Runtime Platform, Release Engineering, Security  
**Related requirements:** INS-002, INS-003, INS-007, SEC-001

## Context

Runtime components are large, shared, security-sensitive, and independently versioned. Filename/version-directory distribution permits accidental mutation and weak provenance. Per-game full copies waste storage.

## Decision

All distributable runtime layers and derived release objects are identified by cryptographic digest, verified before publication/use, and materialized into immutable generation views. Activation uses references to verified objects. Writable state is stored separately.

## Rationale

Content identity enables deduplication, resumable verification, secure distribution, exact rollback, and reproducible support.

## Consequences

### Positive

- Tamper detection.
- Cross-game deduplication.
- Atomic publication.
- Safe partial-download recovery.
- Exact provenance and SBOM binding.
- Garbage collection by reference.

### Negative / cost

- CAS and reference-accounting complexity.
- User-facing storage attribution is less intuitive.
- Object fragmentation and materialization performance require tuning.
- Garbage-collection bugs can waste space or threaten availability.

## Alternatives considered

1. **Versioned directories only:** insufficient content identity and deduplication.
2. **Package-installer mutation:** poor rollback.
3. **Full disk images:** simpler immutability but less granular sharing and update.

## Validation and implementation notes

Fault-test download, verification, publication, materialization, concurrent references, GC leases, corruption, low disk, and rollback. Measure APFS clone, hard-link, and copy trade-offs.

## Revisit triggers

Materialization and chunking may change. Cryptographic content identity and immutable activation remain required.
