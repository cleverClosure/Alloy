# Alloy Risk Register

**Version:** 1.0  
**Status:** Active planning register  
**Date:** 20 July 2026  
**Owner:** Program Management with named risk owners  
**Related:** [Product strategy](01_PRODUCT_STRATEGY.md) · [Roadmap](11_ROADMAP_TEAM_AND_DELIVERY.md) · [Security](09_SECURITY_PRIVACY_THREAT_MODEL.md)

---

## 1. Scoring

- **Probability:** Low, Medium, High.
- **Impact:** Medium, High, Critical.
- A Critical impact threatens user trust, legal operation, platform viability, or company survival.
- Risk owners review triggers and mitigation evidence at each planning increment.
- A risk is not “mitigated” merely because work started.

## 2. Register

| ID | Risk | Category | Probability | Impact | Trigger / early signal | Mitigation | Contingency | Owner | Decision horizon |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R-001 | CPU translation correctness/performance | Technical | High | Critical | Representative x64 games fail exceptions, mixed ABI, self-modifying code, or CPU-bound frame targets. | Phase-0 ISA/ABI/game spikes; upstream FEX relationship; side-by-side reference provider; profiling and conformance. | Narrow catalog/CPU-heavy exclusions; extend bootstrap path only within legal/platform window; publisher-native assistance. | CTO / CPU Lead | Phase 0 |
| R-002 | Wine ARM64EC integration complexity | Technical | High | High | Loader/wineserver/WoW64 behavior requires larger downstream fork than planned. | Keep stable provider hooks small; upstream early; automated rebase and differential suites. | Temporarily pin known-good Wine generations per title; staff additional Wine expertise. | Wine Lead | Phase 0–1 |
| R-003 | Metal12 schedule exceeds runway | Technical/Business | High | Critical | D3D12 feature subset and title correctness take materially longer than commercial plan. | Vertical slices from day one; prioritize catalog-driven subset; reuse shader tooling where licensed; explicit kill gates. | Launch D3D11-focused paid beta; narrow Metal12 catalog; pursue publisher SDK/tooling revenue. | CTO / Graphics Lead | Phase 0 onward |
| R-004 | D3D12 semantic gap with Metal | Technical | High | Critical | Descriptors, barriers, virtual addresses, sparse resources, queues, or shader semantics cannot meet important games. | Conservative correctness model; feature masks; differential traces; game-driven conformance; Apple GPU specialists. | Exclude unsupported feature paths/titles; publisher adapters; defer affected titles until Metal12 covers the path (no commercially distributable bootstrap provider exists per SPIKE-LEGAL-001). | Metal12 Lead | Phase 0–4 |
| R-005 | Shader compiler quality/stutter | Technical | High | High | Compilation errors or synchronous PSO creation causes corruption or severe frame-time spikes. | Large DXIL corpus; async compilation; persistent versioned cache; prewarming; isolated compiler; binary archives. | Title-specific certified settings; publisher precompile metadata; defer problematic titles. | Shader Compiler Lead | Phase 1–4 |
| R-006 | Unified-memory pressure and leaks | Technical | High | High | Long sessions exhaust memory or degrade the whole system, especially low-memory Macs. | Explicit budgets, pressure telemetry, endurance tests, resource-lifetime instrumentation, cache quotas. | Raise per-title minimum memory; lower virtual VRAM; disable features; graceful termination and recovery. | Graphics Memory Lead | Phase 1–3 |
| R-007 | Frame pacing worse than average FPS suggests | Technical/Product | High | High | Product demos look good but user experience has shader stalls, synchronization bubbles, or uneven presentation. | Percentile/stutter gates, Metal profiling, queue/barrier telemetry, cold/warm scenarios. | Reduce settings/feature scope; pin provider; targeted engine workarounds. | Performance Lead | Phase 1 onward |
| R-008 | macOS JIT/entitlement/platform policy change | Platform | Medium | Critical | Apple changes dynamic-code, notarization, security, or distribution behavior. | Use supported APIs; minimal entitlements; Apple developer relations; OS betas; no undocumented kernel dependency. | Raise minimum OS, redesign JIT helper, narrow distribution model, seek publisher-native path. | CTO / Security | Continuous |
| R-009 | Rosetta removal before production CPU path | Platform | Medium | High | Bootstrap/reference execution becomes unavailable on new macOS earlier than expected or outside game scope. | Treat Rosetta as optional only; production FEX path is Phase-0 critical. | Freeze bootstrap development environment; exclude unsupported OS until production path ready. | CPU Lead | Phase 0–2 |
| R-010 | Third-party redistribution/licensing blocker | Legal | Medium | Critical | GPTK components, codecs, redistributables, storefront installers, or dependencies cannot be shipped as planned. | Early specialist legal review; explicit provenance/license gates; user/storefront/publisher acquisition paths. SPIKE-LEGAL-001 preliminary matrix (23 Jul 2026, `docs/research/`) found no fatal blocker; residual items: GPTK user-fetch fragility, Steam SSA §4.C automation text, codec content-royalty campaigns. | Replace component; require user-supplied licensed content; narrow features/catalog; accelerate owned implementation. | Legal / Release | Phase 0 |
| R-011 | Storefront terms or behavior change | External | Medium | High | Authentication, update, or install workflow breaks or terms restrict integration. | Adapter abstraction; test automation; formal conversations where possible; no credential interception. | Support another storefront/standalone; native launcher handoff; temporarily stale status. | Storefront Lead | Continuous |
| R-012 | Launcher update cadence overwhelms support | Operational | High | High | Launchers/embedded browsers change more often than games and invalidate many titles. | Per-process isolation; launcher fingerprints; shared launcher test suites; centralized adapter team. | Pin launcher where contractually possible; use native storefront integration; downgrade affected status. | Storefront + Compat | Beta onward |
| R-013 | Game update volume exceeds lab capacity | Operational | High | High | Certification backlog makes public statuses stale. | Impact graph, risk-based scheduling, smoke/full tiers, automation, top-catalog prioritization. | Reduce certified catalog; extend evidence only with justified equivalence; add hardware capacity. | Head of Compatibility | Beta onward |
| R-014 | Automated scenarios are flaky or non-deterministic | Quality | High | High | False regressions consume engineering or real regressions are masked. | Stable checkpoints, structured anchors, retry visibility, flaky ownership, manual expert review. | Lower automation scope and use curated manual gates for specific titles; do not hide retries. | Lab Lead | Phase 1 onward |
| R-015 | Windows reference is not comparable | Quality | Medium | Medium | Driver/vendor differences create noisy visual/API comparisons. | Classify exact/tolerance/behavioral comparisons; fixed Windows images; focus on observable correctness. | Use reference only for selected signals; establish game-specific baselines. | Lab Lead | Phase 1 onward |
| R-016 | Certification badge overpromises | Product/Trust | Medium | Critical | Users interpret a limited scenario as universal completion or all settings/modes. | Exact scope and limitations; level definitions; stale/host mismatch states; product review. | Downgrade/reword status; public incident correction; stricter future gate. | Head of Product | MVP onward |
| R-017 | Save data loss or corruption | Reliability/Trust | Low | Critical | Lifecycle bug deletes or overwrites saves. | Separate volumes, backups, transactional operations, fault tests, no cascade delete, explicit UX. | Immediate release stop; recovery tooling; user support/compensation; root-cause program. | Runtime Lead | MVP onward |
| R-018 | Security escape from untrusted guest code | Security | Medium | Critical | Parser/JIT/IPC/filesystem flaw compromises host or credentials. | Least privilege, process isolation, fuzzing, W^X, brokered files, secure IPC, external testing. | Emergency revoke/update; disable vulnerable provider/feature; incident response. | Security Lead | Continuous |
| R-019 | Signing or supply-chain compromise | Security | Low | Critical | Malicious runtime/profile is distributed. | Offline root, role separation, hardware-backed keys, provenance/SBOM, reproducible builds, audit. | Revoke keys/targets, safe rollback, emergency client update, public incident response. | Security / Release | Before MVP |
| R-020 | Diagnostics collect sensitive data | Privacy | Medium | Critical | Logs/bundles contain credentials, paths, chat, saves, or private publisher data. | Redaction at source, preview/consent, scanners, bounded logs, data classification and retention. | Disable uploads, purge data, notify, patch redaction, incident response. | Privacy Lead | Before MVP |
| R-021 | Custom Mode contaminates Certified Mode | Security/Product | Medium | High | User modifications persist into certified sessions or anti-cheat identity is ambiguous. | Separate generations/volumes, verification before launch, visible integrity state, reset path. | Block certification, rebuild verified generation, disable affected integration. | Runtime + Security | Beta |
| R-022 | Anti-cheat vendors do not enable platform | Partnership | High | High | Competitive multiplayer remains unsupported despite technical quality. | Honest scope; early vendor design partners; signed integrity model; publisher leverage. | Focus single-player/co-op; GA without broad competitive support; publisher-specific pilots. | Partnerships | GA track |
| R-023 | Publisher adoption is slow | Business | Medium | High | Publisher portal/services do not generate partnerships or differentiation. | Consumer-first value; precise reports; design partners; no mandatory source port. | Delay portal investment; sell diagnostics/SDK to selected publishers; focus consumer. | CEO / Partnerships | Beta–GA |
| R-024 | Users value catalog breadth over reliability | Market | High | High | Curated catalog is perceived as too small. | Pick high-demand titles; publish honest tiers; community experimental mode; show update reliability; state the modern-only focus (ADR-0011) as deliberate depth-over-breadth positioning. | Expand Playable tier with clear separation; partner with publishers; adjust pricing. | Product / Marketing | MVP onward |
| R-025 | Willingness to pay is insufficient | Business | Medium | Critical | Subscription revenue cannot support ongoing compatibility engineering. | Early pricing research; paid private beta; measure retention/CSPH; publisher revenue experiments. | Narrow premium catalog; B2B tooling/SDK; licensing/partnership pivot. | CEO / Product | Before public beta |
| R-026 | Support cost scales linearly with catalog | Operational/Business | High | High | Each additional title requires recurring manual specialist work. | Automation, shared engine/launcher fixes, profiles, evidence graph, support bundle reproduction. | Cap catalog; price by service cost; community experimental tier; retire low-use titles transparently. | Head of Compatibility | Beta onward |
| R-027 | Cloud/lab cost exceeds plan | Financial | Medium | High | Artifacts, traces, physical hardware, and test time create poor unit economics. | Budgets/quotas, content dedup, impact tests, sampling, tiered retention, capacity model. | Reduce matrix/scenario scope with evidence; increase price; publisher co-funding. | SRE / Finance | Beta onward |
| R-028 | Apple introduces native/competing solution | Market/Platform | Medium | High | OS/vendor stack reduces differentiation or changes access. | Own evidence/runtime operations and publisher trust; avoid dependency-only moat; maintain strong Metal path. | Partner/license; shift to certification/SDK/publisher tools; integrate new platform capability. | CEO / CTO | Continuous |
| R-029 | Open-source relationship deteriorates | Ecosystem | Low | High | Large proprietary fork or poor upstream behavior increases maintenance and reputation risk. | Upstream generic fixes, clear boundaries, dedicated maintainers, attribution/license discipline. | Fund maintainers; reduce fork; replace isolated dependency only with explicit cost. | CTO / Open Source Lead | Continuous |
| R-030 | Key-person dependency | Organization | High | High | Rare graphics/Wine/JIT expertise is concentrated in one person. | Pairing, design docs, ADRs, test ownership, succession, competitive retention. | Consultants/advisors, scope reduction, targeted hiring/acquisition. | CEO / CTO | Immediate |
| R-031 | Hardware matrix assumptions are wrong | Quality | Medium | High | GPU family or memory class equivalence hides device-specific failures. | Capability-based IDs, representative hardware, field signals, expand matrix on evidence. | Downgrade affected hosts; buy capacity; split host classes. | Lab / Graphics | Beta onward |
| R-032 | macOS update causes broad regression | Platform/Operational | High | High | New OS changes Metal, JIT, input, media, filesystem, or permissions. | Developer/beta OS testing, host deny rules, per-OS certification, canary, user messaging. | Temporarily block/mark stale on new OS; pin previous provider; expedited compatibility release. | Platform Lead | Continuous |
| R-033 | 32-bit helper processes in modern titles | Technical/Product | Medium | Medium | A shortlisted modern x64 title requires a 32-bit launcher/installer/DRM helper. | ADR-0011 permanently excludes 32-bit game executables; catalog hard filter prefers titles without 32-bit helpers; narrow translated-WoW64 helper allowance with conservative per-process policy, never part of gameplay certification. | Drop the affected title, or accept the helper allowance per title with explicit evidence and disclosure. | Wine/CPU Lead | Catalog selection |
| R-034 | No viable deterministic automation for key games | Quality/Product | Medium | High | Open-world/random/network titles cannot be reliably certified. | Structured checkpoints, publisher hooks, manual scripted review, statistical tests. | Certify limited paths/modes; lower level; require publisher test hook. | Compatibility Lead | Catalog selection |
| R-035 | Product becomes a wrapper before moat arrives | Strategy | High | Critical | Commercial pressure ships UI around third-party stack with no deterministic system or Metal12 path. | Architecture gates; investor/board milestone definitions; separate bootstrap from strategic deliverables. | Narrow/extend preview rather than misposition; publish roadmap honestly. | CEO / CTO | Continuous |
| R-036 | Metal12 IP contamination under solo provenance discipline | Legal/Strategy | Medium | Critical | The Metal12 author reads an excluded LGPL source (vkd3d, vkd3d-proton, DXMT `src/d3d12/`), or a similarity claim is raised against Metal12. | ADR-0012 protocol: exclusion list, spec-only approved inputs (DirectX-Specs/Headers, DXC, Apple docs), append-only provenance log, AI-assistant rules, DXMT-internal boundary. | Incident review with counsel; open-source or rewrite affected modules; adopt formal two-team clean room once headcount permits. | CEO/CTO (founder) / Legal | Continuous from first Metal12 code |

### 2.1 Ratified Phase-0 risk dispositions — 24 July 2026

Ratified by the founder per Phase-0 audit §3.2 (exit criterion E9). Deadlines are
evidence-bound orderings, not calendar dates; changing one requires a new recorded
decision, not an edit to this table.

| Risk | Anchor | Ratified disposition | Tracking |
| --- | --- | --- | --- |
| FEX 4 KB guard granularity | R-001 | CLOSED 24 Jul 2026 — host-page-sized, validated by `guard_enforce` (CPU-001 result 09) | — |
| Multi-worker guest-AV dispatch deadlock | R-001 | Fix lands before any real title boots under the runtime | issue #6 → blocks #10 |
| MXCSR sticky exception-status flags | R-001, R-014 | Fix lands before LAB-001 determinism runs. FMA fusion RETIRED at ratification as a non-defect (CPU-001 result 12: bit-exact single-rounded) | issue #7 → blocks #15 |
| Rip-modify continue-execution hang | R-001 | RETIRED at ratification — green since CPU-001 result 10; no further work scheduled | — |
| Dispatcher-gadget x18 fault tax | R-001, R-007 | Fix lands before Phase-1 performance baselining; fault telemetry stays absorbed in the fork meanwhile | issue #8 |
| Counsel checklist (nine items) | R-010, R-036 | Complete before any external binary distribution | issue #13 → blocks #16 |
| LAB-001 Windows lab hardware | R-014, R-015 | Purchase in Phase-1 week 1 | issue #15 |

## 3. Top program risks

The current top risks requiring executive visibility are:

1. production CPU translation viability;
2. Metal12 schedule and semantic scope;
3. third-party redistribution/licensing;
4. compatibility-lab throughput versus update volume;
5. save/security incident;
6. subscription willingness to pay;
7. the product shipping as a wrapper before its moat exists;
8. Metal12 provenance discipline while the team is one person (R-036).

## 4. Risk review cadence

### Weekly

- new trigger or changed probability/impact;
- blocked mitigation;
- security/legal risk;
- critical-path CPU/Metal12;
- title or storefront regression.

### Per six-week increment

- evidence against hypothesis;
- contingency readiness;
- expected runway/cost effect;
- residual risk accepted by whom;
- required PRD/architecture/roadmap change.

### Before release

- all Critical risks have explicit launch disposition;
- no unowned risk;
- contingency/runbook tested where practical;
- user-facing limitations match accepted risk;
- waivers have expiry and sign-off.

## 5. Risk decision record

For any accepted High/Critical residual risk, record:

```text
risk ID
decision and rationale
evidence reviewed
scope affected
user/partner disclosure
owner
approval authority
expiration/review trigger
contingency
```

## 6. Early-warning dashboard

Track:

- CPU conformance/performance trend;
- Metal12 feature and game vertical-slice trend;
- downstream Wine patch count/age;
- lab queue and certification staleness;
- severe field regression and MTTR;
- save lifecycle failures;
- security fuzz unique crashes;
- redistribution/legal gates;
- certified title maintenance hours;
- cloud/lab cost per certified title;
- paid conversion/retention;
- publisher and anti-cheat pilot status;
- key-person ownership concentration.
