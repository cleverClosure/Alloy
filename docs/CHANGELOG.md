# Documentation Changelog

## 1.3 — 23 July 2026

Phase 0 target decisions: first storefront and MVP game portfolio.

- added `research/SPIKE-STORE-001-findings.md`: Steam/GOG/Epic evaluated from primary sources — Steam SSA §4.C automation and §2.G protocol-emulation clauses quoted (version 20 Apr 2026); Steam Windows client 64-bit since Dec 2025; GOG Galaxy API verified to expose no build identity (installer-metadata fingerprinting instead); Epic store EULA + account ToS both analyzed;
- added `research/SPIKE-CATALOG-001-findings.md`: 44 titles fact-checked with live sources — native-port exclusion list, demand ranking, anti-cheat ceiling (EAC/BattlEye ≈ 60% of protected titles, no macOS opt-in), 42-candidate engineering matrix, weighted scoring, and the approved portfolio;
- decisions D-019 (first storefront: Steam; GOG at MVP+1; Epic deferred) and D-020 (13-title portfolio: Sir Brante smoke test; certified core Sekiro, The Witcher 3, God of War 2018, NieR: Automata, Yakuza: Like a Dragon, Persona 5 Royal, Dark Souls III, DOOM Eternal, Red Dead Redemption 2; Metal12 lab targets Manor Lords, Ghost of Tsushima DC, Kingdom Come: Deliverance II); D-013 resolved to Accepted;
- doc 16: SPIKE-STORE-001 and SPIKE-CATALOG-001 closed with findings pointers; decision schedule updated; doc 14 pending-decisions list updated;
- cross-cutting findings recorded for later spikes: AVX2 boot requirements (FF VII Rebirth, FF XVI) scope the FEX conformance corpus; Elden Ring EAC applies even offline; live Denuvo verification corrected several stale community assumptions;
- manifests regenerated.

## 1.2 — 23 July 2026

Package-wide consolidation: one source of truth per fact, single-responsibility documents, conflict and redundancy removal.

- canonical ownership enforced: support statuses (PRD §14), certification levels/gates (07), risks (13), roadmap/phases/teams (11), ADRs (`adr/` + 14), business model (01 §10), contract semantics (05 + schemas), publisher workflows (17);
- architecture doc: colliding embedded mini-ADR register replaced with a pointer/mapping to the canonical `adr/` directory; duplicate Phase A–F roadmap and team-topology tables replaced with phase-letter-free technical sequencing constraints deferring to doc 11; §25 budgets explicitly subordinated to PRD NFRs;
- added ADR-0013 (continuous differential certification on physical fleets — promoted from an orphaned embedded decision) and decision-log row D-018;
- status model unified: PRD §14 canonical (9 statuses + derived/orthogonal presentation note); 03 §5.1 labels declared presentation-only; 07 levels declared the evidence-bearing subset, both certification checklists (Certified §3.6, Competitive Certified §3.7) stated once with release-gating deltas only; "Unsupported Multiplayer" wording removed;
- contract chain reconciled: example runtime drive now read-only per 05 §13 invariant; `settings` drive-mapping target added to schema and prose; 05 §21.7 lifecycle→release-ring mapping added and doc 06 aligned; LaunchSpecification/policy snapshot explicitly declared locally derived (05 §3/§18/§19, 06 §9); host-class registry ownership defined (05 §7.1, 06 §12);
- bootstrap-D3D12 hedges removed everywhere: no commercially distributable bootstrap exists (SPIKE-LEGAL-001); GPTK is lab/reference-only (PRD §9.1/§18.1/§22, 01 §11/§13, 04 §2.6/§14.1/§15.12/§32.1, 11 assumptions/Phase-0, 13 R-004, ADR-0006 constraint update);
- 03 §18 publisher-portal UX replaced with pointer to 17; 17 portal requirements gained update-regression notification (PUB-006) and workaround-comment scope; PRD §17 compressed to binding principles + pointer to 01 §10; PRD §20 risk summary tagged with register IDs; CAT-003 references the full §14 model;
- ADR-0011/0012 alignment stragglers fixed across 08 (memory matrix, DirectInput/DirectSound scope, media codecs), 15 (glossary entries + "Modern baseline"), 16 (SPIKE-LEGAL-001 marked partially closed), README (key decisions, research/ tree), 00 (research/ tree), CONTRIBUTING (§9 provenance rules per ADR-0012);
- manifests regenerated; schemas re-validated; example profile re-validated; all relative links verified.

## 1.1 — 23 July 2026

Modern-baseline scope decision and legal research:

- added ADR-0011 (modern baseline only: x64 guest games, D3D10/11/12/Vulkan renderers, rolling macOS window of current + previous major, 16 GB certified memory floor, storefront-managed installs; 32-bit game executables and D3D9-and-earlier/DirectDraw/OpenGL permanently out of scope);
- added ADR-0012 (Metal12 provenance protocol: proprietary implementation under a discipline-model clean room; vkd3d, vkd3d-proton, and DXMT `src/d3d12/` are excluded sources);
- added `research/SPIKE-LEGAL-001-preliminary-findings.md` (component-by-component redistribution matrix; requires counsel review);
- PRD: non-goals, MVP scope, and product constraints updated for the modern baseline;
- risk register: R-010 downgraded to Medium probability after legal findings; R-033 reframed to 32-bit helper processes; new R-036 (Metal12 IP contamination); top-risk list and R-024 updated;
- architecture: compatibility target, macOS window, provider matrices, §11.5, §16, roadmap/team/open-question references aligned to ADR-0011;
- profile/manifest spec and game-profile schema: legacy graphics provider identifiers removed (schema v1 → v1.1 pre-release breaking change);
- spikes: CATALOG-001 hard filters, STORE-001 client x64-purity criterion, MEDIA-001 modern-codec rescope, INPUT-001 certified input scope, M12-004 memory classes 16/24/32/64 GB;
- decision log: D-016 and D-017 recorded; document map assumptions updated;
- MVP epics: storefront-managed installs; 32-bit catalog removed from cut rules.

## 1.0 — 20 July 2026

Initial integrated product documentation package:

- product strategy;
- full PRD with functional and non-functional requirements;
- UX and user journeys;
- full technical architecture in Markdown;
- runtime profile and manifest specification;
- API and data contracts;
- compatibility certification specification;
- test and quality strategy;
- security, privacy, and threat model;
- observability, operations, and release plan;
- roadmap, team, and delivery plan;
- requirements traceability matrix;
- risk register;
- decision log and ten ADRs;
- glossary;
- open questions and technical spikes;
- publisher and anti-cheat integration specification;
- JSON Schemas and example game profile.
