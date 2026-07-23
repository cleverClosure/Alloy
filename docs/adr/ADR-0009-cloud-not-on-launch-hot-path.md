# ADR-0009: Keep the Cloud Off the Installed Launch Hot Path

**Status:** Accepted  
**Date:** 20 July 2026  
**Decision owners:** Product, Runtime Platform, SRE  
**Related requirements:** CAT-006, NFR-REL-005

## Context

A cloud-required compatibility layer would make locally installed games dependent on Alloy availability and create poor offline ownership. Profiles and artifacts are signed and can be verified locally.

## Decision

An installed title with cached valid metadata/objects and compatible storefront policy can resolve and launch locally without a live Alloy request. Cloud services distribute updates, certification, and optional diagnostics but are not required for normal launch.

## Rationale

This improves resilience, reduces latency, limits outage blast radius, and aligns with user expectations for local gaming.

## Consequences

### Positive

- Offline play.
- Cloud outage does not disable the installed library.
- Lower launch latency and service load.
- Signed metadata remains authoritative.

### Negative / cost

- Cached metadata expiry/revocation policy is complex.
- Entitlement/subscription design must accommodate offline use.
- Clients need a robust local resolver/database.
- Field health may be delayed while offline.

## Alternatives considered

1. **Always-online launch authorization:** rejected for product resilience.
2. **Long-lived opaque server token only:** weak exact metadata semantics.
3. **No cloud:** incompatible with continuous certification/distribution.

## Validation and implementation notes

Chaos-test complete cloud outage, expired metadata states, revocation after reconnect, offline storefront behavior, and local database recovery.

## Revisit triggers

Review entitlement cadence and security expiry separately. A commercial policy must not silently turn the technical launch path into an always-online dependency.
