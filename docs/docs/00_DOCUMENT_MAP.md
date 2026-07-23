# MGCR Documentation Map and Governance

**Version:** 1.0  
**Date:** 20 July 2026  
**Working name:** Mac Gaming Compatibility Runtime (MGCR)

---

## 1. Reading order

### Executive / founder

1. [Product Strategy](01_PRODUCT_STRATEGY.md)
2. [Product Requirements Document](02_PRD.md)
3. [Roadmap, Team, and Delivery](11_ROADMAP_TEAM_AND_DELIVERY.md)
4. [Risk Register](13_RISK_REGISTER.md)
5. [Technical Architecture](04_TECHNICAL_ARCHITECTURE.md)

### Product and design

1. [PRD](02_PRD.md)
2. [UX and User Journeys](03_UX_AND_USER_JOURNEYS.md)
3. [Certification Specification](07_COMPATIBILITY_CERTIFICATION_SPEC.md)
4. [Requirements Traceability](12_REQUIREMENTS_TRACEABILITY_MATRIX.md)

### Runtime/graphics engineering

1. [Technical Architecture](04_TECHNICAL_ARCHITECTURE.md)
2. [Runtime Profile and Manifest Specification](05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md)
3. [API and Data Contracts](06_API_AND_DATA_CONTRACTS.md)
4. [Test and Quality Strategy](08_TEST_AND_QUALITY_STRATEGY.md)
5. [`adr/`](../adr/)

### Security, SRE, and release

1. [Security, Privacy, and Threat Model](09_SECURITY_PRIVACY_THREAT_MODEL.md)
2. [Observability, Operations, and Release](10_OBSERVABILITY_OPERATIONS_AND_RELEASE.md)
3. [Test and Quality Strategy](08_TEST_AND_QUALITY_STRATEGY.md)
4. [Risk Register](13_RISK_REGISTER.md)

### Compatibility and publisher teams

1. [Certification Specification](07_COMPATIBILITY_CERTIFICATION_SPEC.md)
2. [Publisher and Anti-Cheat Integration](17_PUBLISHER_AND_ANTI_CHEAT_INTEGRATION.md)
3. [Runtime Profile Specification](05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md)
4. [Open Questions and Technical Spikes](16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md)

## 2. Document inventory

| Document | Authority | Purpose |
| --- | --- | --- |
| Product Strategy | Directional | Product thesis, wedge, moat, commercial hypotheses |
| PRD | Normative product | Goals, scope, requirements, release gates, success metrics |
| UX and User Journeys | Normative experience | Information architecture, flows, states, language, accessibility |
| Technical Architecture | Normative engineering | Full system architecture and quality constraints |
| Profile/Manifest Spec | Normative contract | Signed compatibility and runtime configuration semantics |
| API/Data Contracts | Normative interface baseline | Local/cloud APIs, ABIs, events, data models |
| Certification Spec | Normative product/quality | Support levels, test scope, evidence, expiry |
| Test/Quality Strategy | Normative verification | Test layers, lab, performance, release gates |
| Security/Privacy Threat Model | Normative security | Assets, threats, controls, privacy, incident gates |
| Operations/Release | Normative operational | SLOs, rings, rollback, support, incident and DR |
| Roadmap/Team | Planning | Sequence, staffing, milestones, critical path |
| Traceability Matrix | Governance | Requirement-to-owner/architecture/test mapping |
| Risk Register | Governance | Risks, triggers, mitigations, contingencies |
| Decision Log and ADRs | Normative decisions | Long-lived choices and revisit conditions |
| Glossary | Reference | Shared terminology |
| Open Questions/Spikes | Discovery | Evidence required before unresolved decisions |
| Publisher/Anti-Cheat Spec | GA-track product | Partner workflow, reports, integrity integration |
| Legal/Open-Source/Distribution | Normative compliance plan | Dependency rights, redistribution, notices, storefront/protection review |
| MVP Epics and Backlog | Planning | Integrated work packages and non-cuttable MVP core |

## 3. Source of truth hierarchy

When documents conflict:

1. approved legal/security policy and signed release metadata;
2. approved PRD for player-facing commitments;
3. approved architecture and ADRs for implementation boundaries;
4. normative specifications for contracts and certification;
5. traceability matrix for current planned mapping;
6. roadmap and strategy for sequencing/hypotheses;
7. examples and diagrams for illustration.

A conflict must be resolved by editing the documents, not by relying on this hierarchy indefinitely.

## 4. Versioning

Documents use semantic intent:

- **Major:** product/architecture contract breaks or major scope changes.
- **Minor:** material additive requirements/sections/decisions.
- **Patch:** clarification without changing behavior.

Each stable release records:

- PRD revision;
- architecture revision;
- schema/profile versions;
- traceability revision;
- certification/test-plan revisions.

## 5. Normative language

MUST, MUST NOT, SHOULD, SHOULD NOT, and MAY are normative only in documents marked normative. Directional/planning documents may use them to restate an approved requirement but cannot override the PRD or architecture.

## 6. Review authorities

| Change | Required review |
| --- | --- |
| Player promise, support level, data deletion | Product, Engineering, Security/Privacy |
| Runtime/system boundary | Architecture Council |
| Profile/schema/API breaking change | Owning platform teams + Compatibility + Security |
| Signing, JIT, filesystem, secrets, anti-cheat | Product Security |
| Telemetry/diagnostics | Privacy + Data + Product |
| Publisher private data | Security + Partnerships + Legal |
| Third-party component/distribution | Legal + Security + Release |
| Stable certification | Compatibility + subsystem owner + release authority |
| Roadmap/staffing | CEO/CTO/Product/Finance |

## 7. Change workflow

1. Create issue with affected requirement/decision.
2. Draft changes in the smallest authoritative documents.
3. Add or update ADR for long-lived choice.
4. Update traceability and risks.
5. Update schemas/examples if contracts change.
6. Review product, technical, security, quality, operational, and legal impact.
7. Merge with revision history.
8. Bind resulting revision into release/certification evidence where applicable.

## 8. Repository structure

```text
README.md
CHANGELOG.md
CONTRIBUTING.md
docs/
  00_DOCUMENT_MAP.md
  01_PRODUCT_STRATEGY.md
  02_PRD.md
  03_UX_AND_USER_JOURNEYS.md
  04_TECHNICAL_ARCHITECTURE.md
  05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md
  06_API_AND_DATA_CONTRACTS.md
  07_COMPATIBILITY_CERTIFICATION_SPEC.md
  08_TEST_AND_QUALITY_STRATEGY.md
  09_SECURITY_PRIVACY_THREAT_MODEL.md
  10_OBSERVABILITY_OPERATIONS_AND_RELEASE.md
  11_ROADMAP_TEAM_AND_DELIVERY.md
  12_REQUIREMENTS_TRACEABILITY_MATRIX.md
  13_RISK_REGISTER.md
  14_DECISION_LOG.md
  15_GLOSSARY.md
  16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md
  17_PUBLISHER_AND_ANTI_CHEAT_INTEGRATION.md
  18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md
  19_MVP_EPICS_AND_BACKLOG.md
adr/
schemas/
examples/
research/
assets/diagrams/
```

## 9. Machine-readable companions

- [`game-profile.schema.json`](../schemas/game-profile.schema.json)
- [`runtime-manifest.schema.json`](../schemas/runtime-manifest.schema.json)
- [`example-game-profile.yaml`](../examples/example-game-profile.yaml)

The example is illustrative. The schemas are version-one structural baselines and require repository validation before production use.

## 10. Current assumptions

- Apple-silicon-only.
- Modern baseline only (ADR-0011): x64 guest games; D3D10/11/12 and Vulkan renderers; storefront-managed installs; 16 GB certified memory floor.
- Host macOS support is a rolling window of the current and previous majors; 14.4 remains an architecture-discussion reference and the exact first-release minimum is set after Phase-0 evidence.
- One initial storefront.
- Curated D3D11-first MVP.
- Production CPU path is FEX/ARM64EC-oriented but remains a validation gate.
- Metal12 is the strategic D3D12 path.
- Competitive anti-cheat support is partner-enabled only.
- Developer ID distribution, no root daemon/kernel extension.
- Cloud is not on installed launch hot path.

## 11. Additional execution documents

- [Legal, Open-Source, and Distribution Compliance](18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md)
- [MVP Epics and Initial Backlog](19_MVP_EPICS_AND_BACKLOG.md)
