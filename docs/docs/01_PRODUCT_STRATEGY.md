# MGCR Product Strategy

**Version:** 1.0  
**Status:** Proposed  
**Date:** 20 July 2026  
**Related:** [PRD](02_PRD.md) · [Architecture](04_TECHNICAL_ARCHITECTURE.md) · [Roadmap](11_ROADMAP_TEAM_AND_DELIVERY.md)

---

## 1. Strategic premise

The opportunity is not to build a prettier Wine bottle manager. The opportunity is to make **continuous compatibility itself a product**.

A general application compatibility suite optimizes for breadth, user configurability, and long-tail legacy behavior. A gaming-only runtime can instead optimize for:

- exact game and launcher builds;
- per-process rather than per-environment policy;
- Apple GPU and unified-memory behavior;
- frame pacing, shader compilation, input, audio, media, and display correctness;
- continuous regression detection;
- atomic per-title update and rollback;
- publisher evidence and anti-cheat trust.

The product wins when a player trusts the support badge because it describes an exact, recently tested state—not because an anonymous report says the game launched once.

## 2. Strategic problem

The Windows game ecosystem changes independently across many layers:

```text
game content
launcher and storefront
DRM and anti-cheat
Windows API behavior
CPU translation
graphics translation
shader compiler
macOS
Apple GPU generation
input/audio/media services
```

Traditional mutable compatibility environments collapse these dimensions into one installation. When behavior changes, the user and support team cannot reliably identify the cause or reconstruct the last working state.

MGCR separates and versions those dimensions. The strategic asset is the resulting **compatibility evidence graph**: exact inputs, tests, results, regressions, fixes, and certified outputs.

## 3. Market wedge

The first wedge should be:

- Apple-silicon Mac owners with meaningful Windows game libraries;
- premium single-player and cooperative titles;
- games with no mandatory unsupported kernel driver;
- titles where an excellent Mac experience is technically achievable;
- games that collectively exercise important engines and rendering paths;
- users willing to pay for reliability, support, and ongoing updates.

The first release should not chase maximum catalog count. It should prove that certified titles keep working and that failures are diagnosed and mitigated materially faster than in community-managed compatibility workflows.

## 4. Differentiation pillars

### 4.1 Certified game runtime generations

Each supported build has an immutable, signed runtime identity, current evidence, and rollback target. This creates a support promise that a mutable bottle cannot.

### 4.2 Per-process compatibility routing

Launchers, updaters, games, crash reporters, embedded browsers, and auxiliary tools can use different graphics, CPU, synchronization, media, DLL, filesystem, and network policies within one session.

### 4.3 Owned Metal path

The long-term moat is first-party control of Direct3D 12 over Metal, including descriptors, barriers, residency, shaders, pipelines, queues, presentation, HDR, and unified-memory policy. The company can then fix title problems at the correct layer instead of waiting for a black-box dependency.

### 4.4 Continuous compatibility laboratory

Automated Mac and Windows reference runs detect upstream changes, compare behavior, measure performance, and bisect regressions. The lab turns support from anecdotal troubleshooting into an evidence pipeline.

### 4.5 Publisher and anti-cheat trust

A signed Certified Mode, reproducible evidence, pre-release testing, and explicit integrity status create a path to vendor-approved multiplayer that unsupported process patching cannot.

### 4.6 Mac-native product quality

A native client, scoped permissions, controller/audio/display integration, save protection, honest status, and actionable errors make the runtime feel like a gaming platform rather than a developer tool.

## 5. Build, reuse, and partner strategy

| Layer | Strategy | Rationale |
| --- | --- | --- |
| Win32/NT user-mode APIs | Reuse and contribute to Wine | Rewriting decades of behavior is strategically wasteful |
| x86/x64 execution | Adapt and contribute to FEX/ARM64EC path | High complexity; differentiation comes from Mac integration and profiling |
| D3D10/11 | Reuse/extend a Metal-native provider such as DXMT | Faster path to a strong D3D11 catalog |
| D3D12 | Build and own Metal12 | Critical control point and strongest technical moat |
| Native services | Build Mac-specific bridges | Directly affects UX, correctness, and latency |
| Runtime composition | Build and own | Core deterministic product abstraction |
| Compatibility profiles | Build and own | Encodes title knowledge and explainability |
| Lab/certification/control plane | Build and own | Compounding data and operational moat |
| Storefront authentication | Integrate, do not replace | Ownership stays with established storefronts |
| Anti-cheat | Partner and certify | Vendor policy/security problem, not a covert translation problem |

## 6. Competitive strategy

### 6.1 Against general compatibility suites

Do not compete on “number of Windows apps.” Compete on:

- gaming-only quality gates;
- exact build certification;
- per-process policy;
- independent per-title rollback;
- frame-time and long-session evidence;
- transparent status;
- publisher program;
- an owned D3D12-to-Metal path.

### 6.2 Against community wrappers

Community wrappers can move quickly and offer broad experimentation. They usually lack:

- signed reproducible runtime state;
- current automated test evidence;
- support accountability;
- secure update and rollback;
- publisher trust;
- systematic privacy and diagnostics;
- a dedicated graphics/compiler roadmap.

MGCR should remain friendly to open-source communities by upstreaming generic fixes and publishing accurate compatibility information, while reserving certified policy, evidence, and proprietary Metal12 work as commercial assets.

### 6.3 Against cloud gaming

Cloud gaming avoids local compatibility but introduces network latency, recurring infrastructure cost, availability dependence, image compression, library availability constraints, and no offline play. MGCR’s strategic advantage is local execution using the user’s Mac hardware. Cloud streaming may be a separate fallback partnership, but it should not blur the local-runtime thesis.

### 6.4 Against native ports

A high-quality native port can outperform any compatibility layer and should be welcomed. MGCR provides value where a publisher will not fund a full port, wants a low-risk evaluation channel, or needs continuity for an existing Windows catalog. Publisher adapters can also become a bridge toward native optimization.

## 7. Moat model

The moat compounds across four layers:

1. **Technology:** Metal12, Apple-specific execution, memory, synchronization, presentation, and native services.
2. **Data:** exact build fingerprints, traces, benchmark histories, visual baselines, known failure signatures, and workaround outcomes.
3. **Operations:** automated lab coverage, bisection, canary promotion, rollback, and incident response.
4. **Trust:** signed integrity, publisher relationships, anti-cheat enablement, transparent support, and a history of protecting saves.

A UI can be copied. A continuously updated evidence graph linked to a first-party graphics runtime is much harder to copy.

## 8. Catalog strategy

### 8.1 Selection criteria

Candidate games should be scored on:

- fit within the modern baseline: x64 build, D3D10/11/12 or Vulkan renderer, storefront-managed install (ADR-0011);
- active and addressable Mac audience;
- engine and graphics API coverage;
- absence of hard kernel-driver blockers;
- storefront and launcher complexity;
- deterministic testability;
- save-system testability;
- content-update frequency;
- publisher cooperation potential;
- ability to create meaningful gameplay scenarios;
- expected performance on representative Apple silicon;
- legal and redistribution requirements;
- support burden.

### 8.2 Portfolio balance

The initial catalog should include:

- multiple Unreal Engine versions;
- Unity;
- at least two proprietary engines;
- D3D11-heavy and D3D12-heavy titles;
- controller-first and keyboard/mouse titles;
- games with cutscenes and Media Foundation use;
- games with different storefront/launcher topologies;
- a range of memory and shader-compilation behavior;
- both short deterministic scenes and longer endurance scenarios.

### 8.3 Status discipline

Catalog growth cannot come from weakening definitions. “Launches,” “Playable,” and “Certified” must remain materially different. Any public count should break out these levels.

## 9. Go-to-market sequence

### Stage 1 — Technical credibility

- demonstrate deterministic per-title runtimes;
- show launcher and game using different providers;
- publish reproducible before/after regression and rollback evidence;
- show D3D11 quality on representative titles;
- demonstrate early Metal12 milestones;
- recruit expert design partners.

### Stage 2 — Enthusiast private beta

- invite technically sophisticated Mac gamers;
- focus on complete diagnostics and rapid feedback;
- build trust through honest limitations and visible release notes;
- validate willingness to pay for maintained compatibility.

### Stage 3 — Curated public catalog

- market named certified titles rather than vague Windows compatibility;
- publish exact support dates and host coverage;
- emphasize save safety, rollback, and one-click experience;
- add publisher co-marketing where available.

### Stage 4 — Publisher platform

- offer pre-release Mac compatibility reports;
- add optimization and certification services;
- integrate approved anti-cheat and runtime integrity;
- make supported Windows builds a lower-effort Mac distribution option.

## 10. Business model hypotheses

These require customer research and financial validation.

### Consumer

- free compatibility check and library scan;
- paid subscription for certified runtimes, continuous updates, cloud diagnostics, and priority support;
- annual plan aligned with ongoing engineering cost;
- possible family or multi-Mac entitlement;
- no per-game repurchase.

### Publisher

- paid pre-release compatibility testing;
- certification and release support;
- engineering engagements for title-specific optimization;
- enterprise portal and private build retention;
- revenue share or distribution partnership only after the platform has leverage.

### Principles

- the consumer product should not be subsidized entirely by publisher services;
- entitlement checks should permit reasonable offline use;
- compatibility status should never be paywalled in a misleading way;
- paid placement cannot alter certification evidence.

## 11. Strategic metrics

| Layer | Metric |
| --- | --- |
| Player value | Certified Successful Play Hours |
| Reliability | Crash-free and launch-success rate by exact build |
| Update resilience | Regression detection time, mitigation time, rollback success |
| Catalog quality | Certified titles retaining status through updates |
| Engineering leverage | Engineer-hours per certification/re-certification |
| Supportability | Reproduction rate from diagnostic bundles |
| Performance | Title-specific frame-time, stutter, memory, and latency gates |
| Trust | Save-loss incidents, incorrect certification incidents, security incidents |
| Publisher value | Pre-release findings resolved before public launch |
| Moat | Size and retention of the certified D3D12 catalog delivered through Metal12 — the only D3D12 path; no commercially distributable bootstrap exists (SPIKE-LEGAL-001) |

## 12. Strategic kill criteria and pivots

The company should reassess the plan if one or more of these remain true after the corresponding research phase:

- the production CPU execution path cannot meet correctness or performance requirements on macOS;
- legal review finds no viable redistribution path for an MVP before Metal12 is usable;
- a focused D3D11 catalog cannot achieve reliable frame pacing on representative Apple silicon;
- the compatibility lab cannot reproduce and attribute real-world failures at acceptable cost;
- consumer willingness to pay is insufficient for continuous maintenance;
- Apple platform policy makes required JIT or distribution behavior untenable;
- publishers and anti-cheat vendors categorically reject the integrity model;
- Metal12 cannot reach a commercially useful D3D12 feature subset within runway.

A pivot may narrow the product to publisher tooling, a D3D12-to-Metal SDK, a curated compatibility service, or a native-port acceleration platform. These are contingency options, not the primary strategy.

## 13. Immediate strategic decisions

Before committing full build capital, leadership must approve:

1. the first storefront and game shortlist;
2. the macOS minimum and host-class matrix;
3. CPU translation proof criteria;
4. redistribution-compliance execution — the bootstrap-D3D12 question is settled (no commercial bootstrap; lab/reference-only GPTK per SPIKE-LEGAL-001 and ADR-0006); remaining approvals are the LGPL source-publication pipeline and the counsel checklist;
5. Metal12 minimum feature subset;
6. certification-level definitions;
7. consumer pricing research plan;
8. data collection defaults;
9. open-source contribution and proprietary boundary;
10. publisher design-partner targets.

The technical spikes and decision deadlines are recorded in [16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md](16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md).
