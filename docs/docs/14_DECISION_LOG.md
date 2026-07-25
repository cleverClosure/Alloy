# Alloy Architecture and Product Decision Log

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
| D-013 | One initial storefront and narrow catalog | Accepted | Start with one adapter and 8–12 games. | Concentrate reliability and reduce integration variance. | PRD/Roadmap | Resolved concretely by D-019/D-020 (23 July 2026); revisit = second-storefront timing per D-019. |
| D-014 | Anti-cheat through vendor enablement only | Accepted | No covert kernel/protection bypass; Competitive Certified requires explicit scope. | Legal, trust, and security. | [09_SECURITY_PRIVACY_THREAT_MODEL.md](09_SECURITY_PRIVACY_THREAT_MODEL.md) · [07_COMPATIBILITY_CERTIFICATION_SPEC.md](07_COMPATIBILITY_CERTIFICATION_SPEC.md) | Review partner-specific designs. |
| D-015 | Publisher portal is GA-track, not MVP critical path | Accepted | Build consumer/runtime/lab foundation first. | Avoid premature B2B surface before evidence system works. | Roadmap | Advance for a strategic design partner only. |
| D-016 | Modern baseline only | Accepted | x64-only guest games; D3D10/11/12/Vulkan renderers; rolling macOS window (current + previous); 16 GB certified memory floor; storefront-managed installs; legacy APIs and 32-bit game executables permanently excluded. | Depth over breadth at solo scale; shrinks permanent conformance, lab, legal, and support surface. | [ADR-0011](../adr/ADR-0011-modern-baseline-only.md) | Decisive commercial evidence for a legacy segment or team-scale change. |
| D-017 | Metal12 provenance protocol | Accepted | Metal12 stays proprietary; vkd3d, vkd3d-proton, and DXMT `src/d3d12/` are excluded sources; spec-only approved inputs; provenance log; AI-assistant rules. | Preserve the technology moat while legally safe at team size one. | [ADR-0012](../adr/ADR-0012-metal12-provenance-and-clean-room.md) | Supersede with formal two-team clean room when headcount permits; revisit on open-core pivot or contamination event. |
| D-018 | Continuous differential certification on physical fleets | Accepted | Physical Mac and Windows reference fleets with continuous differential runs are product architecture, not optional QA tooling; fleet scale follows catalog scale. | Certification must remain true over time; the Windows oracle enables attribution; the evidence graph is a moat layer. | [ADR-0013](../adr/ADR-0013-continuous-differential-certification.md) | Per-title lab cost makes the catalog plan uneconomic (R-026/R-027), or a cloud-Mac tier proves equivalent for defined evidence classes. |
| D-019 | First storefront: Steam; GOG at MVP+1; Epic deferred | Accepted; **scope narrowed 25 July 2026** | Integrate Steam first (real Windows client in-runtime, ACF/depot build identity, no Steam-protocol emulation per SSA §2.G); pull GOG forward to MVP+1; defer Epic indefinitely. **Narrowed by the pre-counsel [verdict](../research/SPIKE-LEGAL-001-verdict.md) item 6:** the shipped integration is read-only local `appmanifest_*.acf` discovery plus actions the user takes in Steam's own UI. Automated SteamCMD orchestration, automatic login, credential storage and client process control are removed from the v1 design ([doc 18 §9](18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md)); SSA §4.C is the operative clause, and absence of credential interception does not answer it. | Users and the addressable modern catalog concentrate on Steam; GOG's DRM-free installer model is the cleanest lab/CAS fingerprinting fit; Epic is weakest on every integration axis. | [SPIKE-STORE-001 findings](../research/SPIKE-STORE-001-findings.md) | Epic partner interest or must-have exclusive; Steam ToS/enforcement change; counsel review of the §4.C lab-automation mitigations. |
| D-020 | MVP game portfolio: 13 titles | Accepted | Smoke test: Sir Brante. Certified core: Sekiro, The Witcher 3, God of War (2018), NieR: Automata, Yakuza: Like a Dragon (GOG build), Persona 5 Royal, Dark Souls III, DOOM Eternal, Red Dead Redemption 2. Metal12 lab targets: Manor Lords, Ghost of Tsushima DC, Kingdom Come: Deliverance II. Ordered backups recorded. | Satisfies the D3D11-first MVP with 12 engine families, Vulkan coverage (DOOM Eternal, RDR2), a benchmark anchor (RDR2), and floor-class coverage; demand-ranked with live-verified per-title protection/memory facts. | [SPIKE-CATALOG-001 findings](../research/SPIKE-CATALOG-001-findings.md) | Per title: native macOS port ships, protection/anti-cheat change, or SPIKE-GFX-001/SPIKE-LAB-001 validation failure promotes the named backup. |
| D-021 | Phase-0 close-out: bootstrap D3D12 stays lab-only; Metal12 carries the commercial D3D12 path | Accepted (24 July 2026) | GPTK/D3DMetal remains lab/reference-only per its non-commercial license; Metal12 is the commercial D3D12 provider, evidenced by four green micro-prototypes (M12-001..004, 24 July 2026); the ADR-0012 discipline-model clean room is the legal posture pending counsel item 8. | Owns the moat with running-code evidence for its four hardest subproblems; accepted consequence is Metal12 schedule weight through Phases 1–2. | [Phase-0 audit §3.1](../../spikes/PHASE-0-AUDIT.md) · [ADR-0006](../adr/ADR-0006-owned-d3d12-metal-and-reused-d3d11.md) · [ADR-0012](../adr/ADR-0012-metal12-provenance-and-clean-room.md) | Open-source Metal12 (ADR-0012 alternative 1) on contamination event or counsel rejection; revisit feature subset each vertical slice. |
| D-022 | Phase-0 completion: GO | Accepted (25 July 2026) | Phase 0's question — is this architecture viable — is answered yes on running-code evidence in every deliverable: x64 executes at real-title scope (2M decoded instructions across 36 threads, result 19), EC Wine routes, the entitled build boots and renders under the runtime with D3D11 through native DXMT, Metal12's four hard subproblems prototype green, and the transactional runtime survives injected termination. No fundamental blocker surfaced anywhere in the stack. **E3 disposition:** its second representative title moves to the first Phase-1 milestone (one is evidenced; the second is a purchase, not a viability question) — issue #11 carries it. **D10 disposition:** the counsel checklist gates the first external binary, not this decision — issue #13 stays open and unaffected. | Closes Phase 0 on viability while asserting nothing about shippability. Accepted consequences: the product rename remains on the critical path before any external binary; codecs are a release gate; item #24 stays closed as not-reproducible rather than understood, protected by regression tests. | [Phase-0 audit §4](../../spikes/PHASE-0-AUDIT.md) · [PHASE-0-STATUS](../../spikes/PHASE-0-STATUS.md) | Phase-1 milestone review reopens scope if the second title, counsel, or the x18 cost at title scale (#36) invalidates a Phase-0 assumption. |
| D-021 | Product name: Alloy | **At risk — revisit trigger fired (24 July 2026)** | Adopt "Alloy" as the product and app name (Alloy.app), replacing working name "MGCR"; certification lockup "Alloy Certified". **The pre-counsel assessment reads this as a conflict and recommends renaming before the first external binary**: exact ALLOY registrations already cover software/SaaS fields, one claiming use since 2002. Internal development continues under the name; external distribution is gated. | Fusion story (x86 games bonded to Apple Silicon), Metal-API echo, premium engineering register; clear of consumer-gaming namespace on initial screen; alloyplay.com available at decision time. **The original rationale's clearance premise did not survive review.** | CHANGELOG 1.4; [glossary](15_GLOSSARY.md); [pre-counsel verdict](../research/SPIKE-LEGAL-001-verdict.md) item 9 | Trigger has fired. Replacement must be coined/highly distinctive and survive an exact + phonetic + translation + app-store + domain + federal/state search before adoption; do not buy domains, commission branding or file until it does. The old fallback shortlist (Sterling, Ingot, Flint, Portside) is **unscreened** and must clear the same search. |

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
2. formal leadership acceptance of the lab/reference-only D3D12 bootstrap scope (Phase 0 exit criterion; the redistribution question itself is settled by SPIKE-LEGAL-001);
3. Metal12 GA feature subset;
4. minimum macOS version at first external release;
5. certification expiry/provisional launch policy;
6. consumer entitlement and offline policy;
7. diagnostic telemetry defaults by region;
8. scope of first publisher/anti-cheat design partner.

First storefront and MVP game catalog were decided 23 July 2026 (D-019, D-020).
Phase-0 D3D12 scope and Metal12 weight were accepted 24 July 2026 (D-021).
Phase 0 was closed GO on 25 July 2026 (D-022), with E3's second title moved to
the first Phase-1 milestone and D10 gating the first external binary only.

> **Known defect: the identifier D-021 is used twice** — "Phase-0 close-out: bootstrap D3D12 stays lab-only" (24 July 2026) and "Product name: Alloy" (23 July 2026). Both are referenced from records that should not be rewritten casually: the Phase-0 decision is cited by a signed audit block ([Phase-0 audit §3.1](../../spikes/PHASE-0-AUDIT.md)) and the naming decision by [CHANGELOG 1.4](../CHANGELOG.md). Renumbering either touches a signed or historical artifact, so the resolution is a founder call and is tracked separately. Until then, cite D-021 by title, never by number alone.
