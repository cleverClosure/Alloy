# MGCR Architecture and Product Decision Log

**Version:** 1.0  
**Status:** Active  
**Date:** 20 July 2026  
**Owner:** Architecture Council  
**Related:** [Technical architecture](04_TECHNICAL_ARCHITECTURE.md) · [PRD](02_PRD.md) · [`adr/`](../adr/)

---

## 1. Decision policy

Use an ADR when a decision:

- changes a system boundary or irreversible technical direction;
- materially affects product scope, security, data, operations, or licensing;
- creates a long-lived constraint;
- rejects a plausible alternative;
- requires a future revisit trigger.

Statuses:

- **Proposed**
- **Accepted**
- **Superseded**
- **Deprecated**
- **Rejected**

An Accepted decision can still have validation gates.

## 2. Decision register

| ID | Decision | Status | Choice | Rationale | Record | Revisit trigger |
| --- | --- | --- | --- | --- | --- | --- |
| D-001 | Game runtime generation is the unit of support | Accepted | Use exact immutable per-game generations rather than mutable bottles. | Reproducibility, independent rollback, clear certification. | [ADR-0001](../adr/ADR-0001-runtime-generation-unit-of-support.md) | Review only if storage/materialization cost prevents product goals. |
| D-002 | Apply compatibility policy per process before normal imports | Accepted | Launcher, game, updater, and helpers can select different providers and restrictions. | Solves bottle-wide backend conflicts and improves containment. | [ADR-0002](../adr/ADR-0002-per-process-policy-before-imports.md) | Review if Wine loader constraints make the hook unstable. |
| D-003 | Apple-silicon-only host | Accepted | Exclude Intel Macs and build all first-party host code as ARM64. | Reduces architecture/test burden and enables Apple-specific optimization. | [ADR-0003](../adr/ADR-0003-apple-silicon-only.md) | Review only for extraordinary commercial demand. |
| D-004 | Thin Wine fork; upstream generic fixes | Accepted | Do not rewrite Wine or embed title logic in generic Wine code. | Leverage ecosystem and keep rebases feasible. | [ADR-0004](../adr/ADR-0004-thin-wine-fork-and-provider-hooks.md) | Review if required hooks cannot be upstreamed or stabilized. |
| D-005 | FEX/ARM64EC-oriented production CPU path | Proposed/validation required | Use a provider abstraction and adapt FEX with Wine ARM64EC; Rosetta is optional bootstrap/reference. | Avoid strategic dependence on Rosetta and new emulator from scratch. | [ADR-0005](../adr/ADR-0005-fex-arm64ec-execution-path.md) | Phase-0 go/no-go after correctness/performance spikes. |
| D-006 | Own D3D12-to-Metal; reuse D3D10/11 Metal provider | Accepted strategic direction | Build Metal12, while using/extending a maintained D3D10/11 provider. | Own critical roadmap and optimize for Apple GPU semantics. | [ADR-0006](../adr/ADR-0006-owned-d3d12-metal-and-reused-d3d11.md) | Review feature subset and schedule at every vertical slice. |
| D-007 | Content-addressed immutable runtime storage | Accepted | Verified layers by digest, atomic activation, separate writable volumes. | Crash consistency, deduplication, rollback, auditability. | [ADR-0007](../adr/ADR-0007-content-addressed-immutable-runtimes.md) | Review materialization mechanism, not principle. |
| D-008 | Certified and Custom Mode are separate states | Accepted | User modifications never mutate or masquerade as certified state. | Supportability, anti-cheat integrity, safe experimentation. | [ADR-0008](../adr/ADR-0008-certified-and-custom-mode-separation.md) | Review allowed customization surface. |
| D-009 | Cloud is not on installed launch hot path | Accepted | Cached verified metadata and objects support offline local orchestration. | Resilience and player ownership. | [ADR-0009](../adr/ADR-0009-cloud-not-on-launch-hot-path.md) | Review entitlement cadence separately. |
| D-010 | Developer ID distribution, no kernel extension/root daemon | Accepted | Distribute outside Mac App Store with signing/notarization and user-space services. | JIT/game directory requirements without unnecessary privilege. | [ADR-0010](../adr/ADR-0010-user-space-developer-id-distribution.md) | Review if Apple policy changes. |
| D-011 | Signed declarative profiles, no arbitrary stable scripts | Accepted | Profiles express bounded data and are statically validated. | Security, determinism, explainability. | [05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md](05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md) | Review extensibility when new service classes appear. |
| D-012 | Certification is exact, expiring evidence | Accepted | Title name alone is never certified; changes invalidate or stale evidence. | Honest support and continuous operations. | Certification specification | Review evidence equivalence and expiry policy. |
| D-013 | One initial storefront and narrow catalog | Proposed | Start with one adapter and 8–12 games. | Concentrate reliability and reduce integration variance. | PRD/Roadmap | Approve after catalog/storefront discovery. |
| D-014 | Anti-cheat through vendor enablement only | Accepted | No covert kernel/protection bypass; Competitive Certified requires explicit scope. | Legal, trust, and security. | [09_SECURITY_PRIVACY_THREAT_MODEL.md](09_SECURITY_PRIVACY_THREAT_MODEL.md) · [07_COMPATIBILITY_CERTIFICATION_SPEC.md](07_COMPATIBILITY_CERTIFICATION_SPEC.md) | Review partner-specific designs. |
| D-015 | Publisher portal is GA-track, not MVP critical path | Accepted | Build consumer/runtime/lab foundation first. | Avoid premature B2B surface before evidence system works. | Roadmap | Advance for a strategic design partner only. |
| D-016 | Modern baseline only | Accepted | x64-only guest games; D3D10/11/12/Vulkan renderers; rolling macOS window (current + previous); 16 GB certified memory floor; storefront-managed installs; legacy APIs and 32-bit game executables permanently excluded. | Depth over breadth at solo scale; shrinks permanent conformance, lab, legal, and support surface. | [ADR-0011](../adr/ADR-0011-modern-baseline-only.md) | Decisive commercial evidence for a legacy segment or team-scale change. |
| D-017 | Metal12 provenance protocol | Accepted | Metal12 stays proprietary; vkd3d, vkd3d-proton, and DXMT `src/d3d12/` are excluded sources; spec-only approved inputs; provenance log; AI-assistant rules. | Preserve the technology moat while legally safe at team size one. | [ADR-0012](../adr/ADR-0012-metal12-provenance-and-clean-room.md) | Supersede with formal two-team clean room when headcount permits; revisit on open-core pivot or contamination event. |
| D-018 | Continuous differential certification on physical fleets | Accepted | Physical Mac and Windows reference fleets with continuous differential runs are product architecture, not optional QA tooling; fleet scale follows catalog scale. | Certification must remain true over time; the Windows oracle enables attribution; the evidence graph is a moat layer. | [ADR-0013](../adr/ADR-0013-continuous-differential-certification.md) | Per-title lab cost makes the catalog plan uneconomic (R-026/R-027), or a cloud-Mac tier proves equivalent for defined evidence classes. |

## 3. Governance

- Decision IDs are immutable.
- Superseding a decision creates a new ADR and links both directions.
- Code/configuration that violates an Accepted ADR requires explicit review, not a silent exception.
- Every ADR lists consequences and operational effects, not only technical preference.
- PRD and traceability updates accompany decisions that change player-facing commitments.
- Security, legal, and publisher decisions include the relevant approval authority.

## 4. Pending decisions

The highest-priority decisions still requiring evidence are:

1. exact production CPU provider viability;
2. first storefront;
3. MVP game catalog;
4. legally redistributable D3D12 bootstrap;
5. Metal12 GA feature subset;
6. minimum macOS version at first external release;
7. certification expiry/provisional launch policy;
8. consumer entitlement and offline policy;
9. diagnostic telemetry defaults by region;
10. scope of first publisher/anti-cheat design partner.
