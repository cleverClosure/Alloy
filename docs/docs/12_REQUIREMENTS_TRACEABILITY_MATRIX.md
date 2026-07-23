# Alloy Requirements Traceability Matrix

**Version:** 1.0  
**Status:** Planning baseline  
**Date:** 20 July 2026  
**Source requirements:** [PRD](02_PRD.md)  
**Architecture:** [Technical architecture](04_TECHNICAL_ARCHITECTURE.md)  
**Test authority:** [Test and quality strategy](08_TEST_AND_QUALITY_STRATEGY.md)

---

## 1. Purpose

This matrix connects every PRD requirement to:

- priority and target release;
- accountable engineering/product area;
- relevant architecture section;
- primary verification method;
- delivery phase;
- implementation status.

The implementation repository should extend this matrix with links to epics, code, tests, evidence runs, waivers, and release records.

## 2. Status values

| Status | Meaning |
| --- | --- |
| Planned | Approved requirement, not yet implemented |
| In progress | Active work with owner and milestone |
| Implemented | Code complete but not all release evidence |
| Verified | Acceptance criterion passed in required environments |
| Waived | Time-bounded approved exception with risk and expiry |
| Deferred | Removed from current target with PRD approval |
| Rejected | Requirement replaced or invalidated by approved revision |

A P0 requirement cannot be silently marked Deferred or Waived.

## 3. Traceability matrix

| Requirement | Priority | Target | Area | Owner | Architecture | Primary verification | Delivery phase | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CAT-001 | P0 | MVP | Catalog | Product Platform | §6, §18 | Integration test | Phase 2 — D3D11 curated MVP | Planned |
| CAT-002 | P0 | MVP | Catalog | Compatibility Platform | §6.2, §19.2 | Lab + integration | Phase 2 — D3D11 curated MVP | Planned |
| CAT-003 | P0 | MVP | Catalog | Product | §21.10, §22.7 | UX acceptance | Phase 2 — D3D11 curated MVP | Planned |
| CAT-004 | P0 | MVP | Catalog | Product + Compatibility | §19.4, §21 | UI + schema | Phase 2 — D3D11 curated MVP | Planned |
| CAT-005 | P0 | Beta | Catalog | Compatibility Platform | §18.5, §21.8 | Integration + lab | Phase 3/5 — private/public beta | Planned |
| CAT-006 | P1 | Beta | Catalog | Client Platform | §4.3, §20.3 | Offline test | Phase 3/5 — private/public beta | Planned |
| INS-001 | P0 | MVP | Installation | Client Product | §8, §18 | End-to-end | Phase 2 — D3D11 curated MVP | Planned |
| INS-002 | P0 | MVP | Installation | Runtime Platform | §9.6, §24.5 | Fault injection | Phase 2 — D3D11 curated MVP | Planned |
| INS-003 | P0 | MVP | Installation | Runtime Platform | §9.2, §9.7 | Storage test | Phase 2 — D3D11 curated MVP | Planned |
| INS-004 | P0 | MVP | Installation | Runtime Platform | §9.5, §24.6 | Recovery test | Phase 2 — D3D11 curated MVP | Planned |
| INS-005 | P0 | MVP | Installation | Client + Runtime | §9, §25.8 | Integration | Phase 2 — D3D11 curated MVP | Planned |
| INS-006 | P0 | Beta | Installation | Release Engineering | §18.4, §23.6 | Policy gate | Phase 3/5 — private/public beta | Planned |
| INS-007 | P0 | MVP | Installation | Runtime Platform | §9.6, §24.3 | Fault + E2E | Phase 2 — D3D11 curated MVP | Planned |
| INS-008 | P1 | Beta | Installation | Storefront Integrations | §18 | Integration | Phase 3/5 — private/public beta | Planned |
| INS-009 | P0 | MVP | Installation | Client Product | §9.5, §24.6 | UX + E2E | Phase 2 — D3D11 curated MVP | Planned |
| RUN-001 | P0 | MVP | Runtime | Runtime Platform | §6.3, §19.6 | Determinism test | Phase 2 — D3D11 curated MVP | Planned |
| RUN-002 | P0 | MVP | Runtime | Runtime + Wine | §10.1–§10.7 | Integration | Phase 2 — D3D11 curated MVP | Planned |
| RUN-003 | P0 | MVP | Runtime | Wine Team | §11.1, §19 | Repository policy | Phase 2 — D3D11 curated MVP | Planned |
| RUN-004 | P0 | MVP | Runtime | Runtime Platform | §2.1, §11.2 | Binary audit | Phase 2 — D3D11 curated MVP | Planned |
| RUN-005 | P0 | MVP | Runtime | CPU Translation | §12.1–§12.4 | Conformance | Phase 2 — D3D11 curated MVP | Planned |
| RUN-006 | P0 | MVP | Runtime | Graphics | §14, §16 | Integration | Phase 2 — D3D11 curated MVP | Planned |
| RUN-007 | P0 | MVP | Runtime | Graphics D3D11 | §16.1–§16.2 | Conformance + lab | Phase 2 — D3D11 curated MVP | Planned |
| RUN-008 | P0 | GA | Runtime | Metal12 Team | §15 | Conformance + lab | Phase 6 — GA | Planned |
| RUN-009 | P1 | Beta | Runtime | Runtime Performance | §13 | Benchmark | Phase 3/5 — private/public beta | Planned |
| RUN-010 | P0 | Beta | Runtime | Graphics Memory | §15.6–§15.8, §25.6 | Endurance | Phase 3/5 — private/public beta | Planned |
| RUN-011 | P0 | Beta | Runtime | Platform Services | §17 | Integration + lab | Phase 3/5 — private/public beta | Planned |
| RUN-012 | P0 | MVP | Runtime | Security + Client | §23.3 | Install audit | Phase 2 — D3D11 curated MVP | Planned |
| CMP-001 | P0 | MVP | Compatibility | Compatibility Platform | §19, §23.7 | Signature + schema | Phase 2 — D3D11 curated MVP | Planned |
| CMP-002 | P0 | MVP | Compatibility | Compatibility Platform | §10.3–§10.4 | Golden test | Phase 2 — D3D11 curated MVP | Planned |
| CMP-003 | P0 | Beta | Compatibility | Compatibility Engineering | §19.4, §19.8 | Policy gate | Phase 3/5 — private/public beta | Planned |
| CMP-004 | P0 | Beta | Compatibility | Compatibility Lab | §21 | Orchestrator test | Phase 3/5 — private/public beta | Planned |
| CMP-005 | P0 | Beta | Compatibility | Compatibility Lab | §21.4–§21.6 | Lab evidence | Phase 3/5 — private/public beta | Planned |
| CMP-006 | P1 | GA | Compatibility | Compatibility Infrastructure | §21.9 | Chaos/lab | Phase 6 — GA | Planned |
| CMP-007 | P0 | Beta | Compatibility | Product + Compatibility | §19.2, §21.10 | Policy + UX | Phase 3/5 — private/public beta | Planned |
| CMP-008 | P0 | MVP | Compatibility | Runtime Security | §10.10, §23 | Security test | Phase 2 — D3D11 curated MVP | Planned |
| CMP-009 | P0 | Beta | Compatibility | Client + Security | §4.6, §23.10–§23.11 | E2E + audit | Phase 3/5 — private/public beta | Planned |
| CMP-010 | P0 | Beta | Compatibility | Compatibility Platform | §6.5, §21 | Resolver test | Phase 3/5 — private/public beta | Planned |
| CMP-011 | P1 | Beta | Compatibility | Storefront Integrations | §10.8, §18.5 | Integration | Phase 3/5 — private/public beta | Planned |
| CMP-012 | P0 | MVP | Compatibility | Partnerships + Security | §2.7, §23.12 | Policy review | Phase 2 — D3D11 curated MVP | Planned |
| DIA-001 | P0 | MVP | Diagnostics | Observability | §22.1 | Integration | Phase 2 — D3D11 curated MVP | Planned |
| DIA-002 | P0 | MVP | Diagnostics | Observability | §22.2 | Contract test | Phase 2 — D3D11 curated MVP | Planned |
| DIA-003 | P0 | MVP | Diagnostics | Client + Privacy | §22.6–§22.8 | Privacy test | Phase 2 — D3D11 curated MVP | Planned |
| DIA-004 | P0 | MVP | Diagnostics | Observability | §22.4 | Crash test | Phase 2 — D3D11 curated MVP | Planned |
| DIA-005 | P1 | Beta | Diagnostics | Runtime Reliability | §22.5, §24.7 | Fault injection | Phase 3/5 — private/public beta | Planned |
| DIA-006 | P0 | Beta | Diagnostics | Performance | §22.3, §25 | Benchmark contract | Phase 3/5 — private/public beta | Planned |
| DIA-007 | P0 | Beta | Diagnostics | Product + Compatibility | §22.7 | UX acceptance | Phase 3/5 — private/public beta | Planned |
| DIA-008 | P1 | Beta | Diagnostics | Client + Support | §4.3, §22 | E2E | Phase 3/5 — private/public beta | Planned |
| DIA-009 | P0 | MVP | Diagnostics | Privacy | §22.8, §23 | Privacy audit | Phase 2 — D3D11 curated MVP | Planned |
| DIA-010 | P0 | Beta | Diagnostics | Lab + Release | §21.12, §23.6 | Audit | Phase 3/5 — private/public beta | Planned |
| UX-001 | P0 | MVP | Experience | Client Product | §8.1 | Usability test | Phase 2 — D3D11 curated MVP | Planned |
| UX-002 | P0 | MVP | Experience | Client Product | §8, §24 | UX acceptance | Phase 2 — D3D11 curated MVP | Planned |
| UX-003 | P0 | MVP | Experience | Client + Security | §23.4 | Permission E2E | Phase 2 — D3D11 curated MVP | Planned |
| UX-004 | P1 | Beta | Experience | Client + Input | §17.2 | Usability test | Phase 3/5 — private/public beta | Planned |
| UX-005 | P0 | MVP | Experience | Client Product | §9.5, §24.6 | UX + recovery | Phase 2 — D3D11 curated MVP | Planned |
| UX-006 | P0 | Beta | Experience | Product + Compatibility | §21.8, §22.7 | UX acceptance | Phase 3/5 — private/public beta | Planned |
| UX-007 | P1 | Beta | Experience | Client Product | §4.6, §23.10 | E2E | Phase 3/5 — private/public beta | Planned |
| UX-008 | P0 | Beta | Experience | Client Product | §8.1 | Accessibility audit | Phase 3/5 — private/public beta | Planned |
| UX-009 | P1 | Beta | Experience | Client Product | §17.11 | Localization review | Phase 3/5 — private/public beta | Planned |
| UX-010 | P0 | MVP | Experience | Product | §1.2, §8 | Usability test | Phase 2 — D3D11 curated MVP | Planned |
| SEC-001 | P0 | MVP | Security | Security + Release | §23.6 | Adversarial test | Phase 2 — D3D11 curated MVP | Planned |
| SEC-002 | P0 | MVP | Security | Security + Runtime | §23.4, §17.7 | Penetration test | Phase 2 — D3D11 curated MVP | Planned |
| SEC-003 | P0 | MVP | Security | CPU + Security | §23.8, §12 | Security test | Phase 2 — D3D11 curated MVP | Planned |
| SEC-004 | P0 | MVP | Security | Security + Storefront | §18.6, §23.9 | Secret scan | Phase 2 — D3D11 curated MVP | Planned |
| SEC-005 | P0 | Beta | Security | Security + Providers | §23.1–§23.2 | Fuzz + review | Phase 3/5 — private/public beta | Planned |
| SEC-006 | P1 | GA | Security | Security + Partnerships | §23.10, §23.12 | Vendor test | Phase 6 — GA | Planned |
| SEC-007 | P0 | Beta | Security | Release Engineering | §23.6, §28 | Audit gate | Phase 3/5 — private/public beta | Planned |
| SEC-008 | P1 | Beta | Security | Security + Product | §23.11 | E2E | Phase 3/5 — private/public beta | Planned |
| SEC-009 | P0 | Beta | Security | Security + SRE | §23.13 | Incident drill | Phase 3/5 — private/public beta | Planned |
| SEC-010 | P0 | MVP | Security | Security + Legal | §1.4, §23.12 | Review gate | Phase 2 — D3D11 curated MVP | Planned |
| PUB-001 | P1 | GA | Publisher | Publisher Platform | §20.5, §21 | Security + E2E | Phase 6 — GA | Planned |
| PUB-002 | P1 | GA | Publisher | Publisher Platform | §21, §22 | Report acceptance | Phase 6 — GA | Planned |
| PUB-003 | P1 | GA | Publisher | Publisher Platform | §19.8, §20.7 | Workflow test | Phase 6 — GA | Planned |
| PUB-004 | P1 | GA | Publisher | Security + Publisher | §20.5, §22.4 | Access audit | Phase 6 — GA | Planned |
| PUB-005 | P1 | GA | Publisher | Partnerships + Security | §23.12 | Partner acceptance | Phase 6 — GA | Planned |
| PUB-006 | P2 | Post-GA | Publisher | Publisher Platform | §21.8 | Workflow test | Post-GA roadmap | Planned |
| PUB-007 | P2 | Post-GA | Publisher | Platform Services | §15.18, §17 | SDK conformance | Post-GA roadmap | Planned |
| PUB-008 | P1 | GA | Publisher | Publisher Platform | §21 | Partner pilot | Phase 6 — GA | Planned |
| NFR-PERF-001 | P0 | MVP | NFR | Performance / Graphics | §25–§26 | Performance benchmark | Phase 2 — D3D11 curated MVP | Planned |
| NFR-PERF-002 | P0 | Beta | NFR | Performance / Graphics | §25–§26 | Lab benchmark | Phase 3/5 — private/public beta | Planned |
| NFR-PERF-003 | P0 | Beta | NFR | Performance / Graphics | §25–§26 | Graphics benchmark | Phase 3/5 — private/public beta | Planned |
| NFR-PERF-004 | P0 | Beta | NFR | Performance / Graphics | §25–§26 | Endurance test | Phase 3/5 — private/public beta | Planned |
| NFR-PERF-005 | P1 | GA | NFR | Performance / Graphics | §25–§26 | Latency lab | Phase 6 — GA | Planned |
| NFR-PERF-006 | P1 | Beta | NFR | Performance / Graphics | §25–§26 | Storage endurance | Phase 3/5 — private/public beta | Planned |
| NFR-REL-001 | P0 | MVP | NFR | Runtime / SRE | §24 | SLO review | Phase 2 — D3D11 curated MVP | Planned |
| NFR-REL-002 | P0 | MVP | NFR | Runtime / SRE | §24 | Fault injection | Phase 2 — D3D11 curated MVP | Planned |
| NFR-REL-003 | P0 | MVP | NFR | Runtime / SRE | §24 | Recovery suite | Phase 2 — D3D11 curated MVP | Planned |
| NFR-REL-004 | P0 | Beta | NFR | Runtime / SRE | §24 | Canary simulation | Phase 3/5 — private/public beta | Planned |
| NFR-REL-005 | P1 | Beta | NFR | Runtime / SRE | §24 | Chaos test | Phase 3/5 — private/public beta | Planned |
| NFR-REL-006 | P0 | MVP | NFR | Runtime / SRE | §24 | Contract test | Phase 2 — D3D11 curated MVP | Planned |
| NFR-SEC-001 | P0 | MVP | NFR | Security / Release | §23, §28 | Release gate | Phase 2 — D3D11 curated MVP | Planned |
| NFR-SEC-002 | P0 | MVP | NFR | Security / Release | §23, §28 | Install audit | Phase 2 — D3D11 curated MVP | Planned |
| NFR-SEC-003 | P0 | Beta | NFR | Security / Release | §23, §28 | Incident drill | Phase 3/5 — private/public beta | Planned |
| NFR-SEC-004 | P1 | GA | NFR | Security / Release | §23, §28 | Protocol test | Phase 6 — GA | Planned |
| NFR-PRIV-001 | P0 | MVP | NFR | Privacy / Data | §22–§23 | Privacy review | Phase 2 — D3D11 curated MVP | Planned |
| NFR-PRIV-002 | P0 | MVP | NFR | Privacy / Data | §22–§23 | UX/privacy test | Phase 2 — D3D11 curated MVP | Planned |
| NFR-PRIV-003 | P0 | Beta | NFR | Privacy / Data | §22–§23 | Data governance audit | Phase 3/5 — private/public beta | Planned |
| NFR-PRIV-004 | P1 | GA | NFR | Privacy / Data | §22–§23 | Policy test | Phase 6 — GA | Planned |
| NFR-OPS-001 | P0 | MVP | NFR | SRE / Release | §20–§22, §28 | Operational readiness review | Phase 2 — D3D11 curated MVP | Planned |
| NFR-OPS-002 | P0 | Beta | NFR | SRE / Release | §20–§22, §28 | Release pipeline test | Phase 3/5 — private/public beta | Planned |
| NFR-OPS-003 | P0 | Beta | NFR | SRE / Release | §20–§22, §28 | Supply-chain audit | Phase 3/5 — private/public beta | Planned |
| NFR-OPS-004 | P0 | Beta | NFR | SRE / Release | §20–§22, §28 | Audit log review | Phase 3/5 — private/public beta | Planned |
| NFR-OPS-005 | P1 | Beta | NFR | SRE / Release | §20–§22, §28 | Support KPI | Phase 3/5 — private/public beta | Planned |
| NFR-OPS-006 | P1 | GA | NFR | SRE / Release | §20–§22, §28 | Load/cost test | Phase 6 — GA | Planned |
| NFR-EVO-001 | P0 | MVP | NFR | Architecture / Platform | §4, §11, §19 | Contract test | Phase 2 — D3D11 curated MVP | Planned |
| NFR-EVO-002 | P0 | Beta | NFR | Architecture / Platform | §4, §11, §19 | ABI test | Phase 3/5 — private/public beta | Planned |
| NFR-EVO-003 | P1 | Beta | NFR | Architecture / Platform | §4, §11, §19 | Release exercise | Phase 3/5 — private/public beta | Planned |
| NFR-EVO-004 | P0 | Beta | NFR | Architecture / Platform | §4, §11, §19 | Resolver test | Phase 3/5 — private/public beta | Planned |
| NFR-ACC-001 | P0 | Beta | NFR | Client Product | §8 | Accessibility audit | Phase 3/5 — private/public beta | Planned |
| NFR-LOC-001 | P1 | Beta | NFR | Client Product | §17 | Localization test | Phase 3/5 — private/public beta | Planned |

## 4. Required implementation links

For each row, the project tracker or generated matrix must eventually include:

```text
requirement ID
→ product epic
→ architecture component
→ ADR(s)
→ source repositories/modules
→ automated test IDs
→ lab scenario/test plan
→ security/privacy review
→ certification evidence
→ release artifact/profile
→ operational dashboard/runbook
```

## 5. Change-control rules

- A PRD requirement change updates this file in the same review.
- An architecture change that makes a requirement unimplementable triggers PRD review.
- A test removed from a release gate requires replacement evidence or an approved waiver.
- A requirement implemented differently from its architecture mapping requires an ADR.
- Stable release evidence records the exact matrix revision.
- Requirements are never considered Verified based only on a manual demonstration unless the acceptance criterion explicitly requires manual expert review.

## 6. Initial coverage dashboard

| Target | Functional requirements | Non-functional requirements | Expected gate |
| --- | ---: | ---: | --- |
| MVP | 38 | 11 | Developer preview |
| Beta | 28 | 17 | Private/public beta |
| GA | 9 | 4 | General availability |
| Post-GA | 2 | 0 | Extension |

## 7. Release review query

Before any milestone, reviewers must be able to answer:

- Which P0 requirements are not Verified?
- Which waivers are active and when do they expire?
- Which requirements lack automated tests?
- Which requirements lack an operational owner?
- Which architecture components have no linked product requirement?
- Which release artifacts or profiles satisfy each requirement?
- Which exact game/host evidence supports player-facing claims?
