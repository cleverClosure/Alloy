# Alloy Open Questions and Technical Spikes

**Version:** 1.0  
**Status:** Active discovery backlog  
**Date:** 20 July 2026  
**Owners:** CTO and Program Management  
**Related:** [Roadmap](11_ROADMAP_TEAM_AND_DELIVERY.md) · [Risk register](13_RISK_REGISTER.md) · [Decision log](14_DECISION_LOG.md)

---

## 1. Purpose

The project contains several unknowns that cannot be resolved by architecture discussion alone. Each spike must produce executable evidence, measurements, a written conclusion, and a decision. “More research” is not an acceptable terminal outcome.

## 2. Spike template

```text
ID and owner
hypothesis
why it matters
prototype/test
representative games/workloads
metrics and pass/fail thresholds
security/legal constraints
deliverables
deadline
decision enabled
fallback
```

## 3. P0 existential spikes

### SPIKE-CPU-001 — FEX on macOS feasibility

**Hypothesis:** A FEX-derived provider can execute representative x64 Windows games under an ARM64-native Wine/ARM64EC environment with correct exceptions, memory semantics, W^X, and commercially acceptable CPU overhead.

**Prototype:**

- port minimum host abstractions to macOS;
- run x64 ISA/ABI corpus;
- integrate one mixed ARM64EC/x64 process;
- execute two representative games, including one CPU-bound workload;
- implement code-cache persistence;
- collect transitions, exceptions, frame-thread CPU time, and cache metrics.

**Pass evidence:**

- no structural blocker in Mach exception/JIT/memory model;
- conformance target agreed by CPU team;
- representative game reaches deterministic scene;
- performance gap has an actionable optimization plan;
- stable unwind/crash diagnostics;
- legal/open-source contribution strategy approved.

**Decision:** accept/reject/replace ADR-0005.

**Fallback:** alternate translator provider; narrower game catalog; temporary bootstrap path only within platform/legal bounds.

### SPIKE-WINE-001 — ARM64-native Wine and policy hook

**Hypothesis:** Wine can remain close to upstream while exposing a pre-import policy hook and mixed-architecture provider integration.

**Prototype:**

- native ARM64 Wine loader/wineserver;
- start x64 game and x86/x64 helper where applicable;
- obtain policy using exact executable identity before graphics/runtime DLL import;
- launcher uses D3D11 provider, game uses another provider;
- exercise process creation, exceptions, COM, and filesystem.

**Pass evidence:**

- hook is small and testable;
- downstream patch plan is bounded;
- no global environment race;
- child process identity and unknown default work;
- rebase against another upstream revision succeeds.

### SPIKE-LEGAL-001 — Redistribution and reverse-engineering matrix

**Status:** Partially closed. [Preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md) drafted 23 July 2026: no fatal blocker for the overall architecture; GPTK/D3DMetal bootstrap distribution is non-commercial-only (lab/reference use only, per the updated [ADR-0006](../adr/ADR-0006-owned-d3d12-metal-and-reused-d3d11.md)); DXMT relicensed MIT→LGPL-2.1-or-later and its `src/d3d12/` subtree joins the Metal12 clean-room exclusion list ([ADR-0012](../adr/ADR-0012-metal12-provenance-and-clean-room.md)). A [counsel brief](../research/SPIKE-LEGAL-001-counsel-brief.md) turning §7 into per-item questions landed 24 July 2026, and a [pre-counsel risk assessment](../research/SPIKE-LEGAL-001-verdict.md) against it was recorded the same day — **not counsel's answer, and it does not close deliverable D10**. It closed item 3 (GPTK user-fetch: do not ship), escalated item 5 (codecs) to a release gate, corrected item 7's eligibility thresholds, and escalated item 9 to "rename before launch"; items 4 (LGPL relink) and 8 (clean room) carry the binding engineering work. Remaining: **qualified counsel engaged and all nine items answered** (issue #13) before any external binary ships.

**Question:** Which components may be developed with, linked against, bundled, downloaded by the user, or used only in lab environments?

**Review scope:**

- Wine, FEX, DXMT, MoltenVK and dependencies;
- Apple Game Porting Toolkit and shader tools;
- Microsoft redistributables;
- Media Foundation/codecs;
- storefront launchers/installers;
- game files and test accounts;
- reverse engineering/interoperability law by launch jurisdiction;
- trademarks and compatibility claims;
- anti-cheat/vendor terms.

**Deliverable:** component-by-component approved distribution model and mandatory release gates.

**Decision:** MVP legal distribution model and launch countries (bootstrap D3D12 is settled as lab/reference-only; remaining scope is the LGPL/codec/storefront counsel checklist).

### SPIKE-GFX-001 — D3D11 product-quality baseline

**Hypothesis:** A Metal-native D3D11 provider can deliver stable frame pacing and correctness for the MVP catalog.

**Prototype:**

- select 4 candidate games across engines;
- automate cold/warm scenes;
- measure frame percentiles, shader stalls, memory, input/audio/media;
- capture visual reference;
- test launcher/game process split.

**Pass evidence:**

- at least two titles reach proposed Certified gate;
- remaining defects are scoped and fixable;
- long-session memory remains bounded;
- provider integration and licensing are acceptable.

### SPIKE-M12-001 — Descriptor and binding virtualization

**Hypothesis:** D3D12 descriptor heaps/root signatures can map to Metal argument buffers with correct in-flight lifetime and acceptable CPU overhead.

**Prototype:**

- virtual heap and descriptor copy/update;
- dynamic indexing;
- multiple command lists/queues;
- page rollover;
- randomized model test;
- engine trace replay.

**Metrics:**

- zero model mismatch/use-after-recycle;
- bounded memory;
- descriptor update CPU cost target;
- no forced full-table rebuild on common paths.

### SPIKE-M12-002 — Barriers, resource state, and queue scheduling

**Hypothesis:** A conservative state tracker can be optimized into a correct Metal synchronization plan without serializing modern engines.

**Prototype:**

- committed/placed/aliased resources;
- per-subresource states;
- UAV/alias barriers;
- cross-queue fences;
- compare conservative and optimized compiler;
- replay representative traces.

**Pass evidence:**

- randomized correctness;
- no visual corruption;
- measurable redundant synchronization elimination;
- queue overlap in target workloads.

### SPIKE-M12-003 — DXIL-to-Metal shader path

**Hypothesis:** The project can legally and technically build a compiler pipeline for the required shader-model subset.

**Prototype:**

- ingest/validate DXIL;
- normalized shader IR;
- lower resource binding, wave operations, precision, derivatives;
- produce Metal IR/source/library path;
- compare corpus outputs;
- cache compiler provenance.

**Pass evidence:**

- target corpus pass rate;
- deterministic output;
- compiler isolation and diagnostics;
- licensing/provenance approval;
- performance/stutter path.

### SPIKE-M12-004 — Unified-memory residency model

**Hypothesis:** A virtual D3D12 memory model can avoid duplicate staging and pressure collapse across supported memory classes.

**Prototype:**

- committed/placed resources;
- guest budget reporting;
- pressure-aware cache eviction;
- 16/24/32/64 GB tests (16 GB certified memory floor per ADR-0011);
- long-session allocation traces;
- oversubscription failure.

**Pass evidence:**

- stable headroom;
- bounded growth;
- correct alias/lifetime;
- graceful degradation.

## 4. P0 product and operations spikes

### SPIKE-CATALOG-001 — MVP game portfolio

**Status:** Closed (decision D-020, 23 July 2026). [Findings](../research/SPIKE-CATALOG-001-findings.md): 13-title portfolio approved — Sir Brante as pipeline smoke test; a 9-title certified core (8 titles on the D3D11 path plus DOOM Eternal and Red Dead Redemption 2 exercising MoltenVK); Manor Lords, Ghost of Tsushima DC, and Kingdom Come: Deliverance II as Metal12 vertical-slice lab targets; ordered backups and per-title revisit triggers recorded. Scenario feasibility validation remains with SPIKE-GFX-001 and SPIKE-LAB-001.

**Question:** Which 8–12 games maximize user value and technical learning while avoiding hard blockers?

Hard filters (ADR-0011 modern baseline) applied before scoring:

- x64-only game executable (no 32-bit gameplay dependency);
- primary renderer Direct3D 10/11/12 or Vulkan;
- officially supports Windows 10 x64 or later;
- storefront-managed installation;
- no required 32-bit-only middleware beyond an approved launcher helper.

Score candidates on:

- demand and willingness to pay;
- engine/API diversity;
- deterministic automation;
- storefront complexity;
- protection technology;
- memory/performance fit;
- publisher opportunity;
- update frequency;
- legal/test access;
- support burden.

**Deliverable:** ranked portfolio with backup titles and scenario plan.

### SPIKE-STORE-001 — First storefront

**Status:** Closed (decision D-019, 23 July 2026). [Findings](../research/SPIKE-STORE-001-findings.md): Steam first — real Windows Steam client runs inside the runtime (no protocol emulation per SSA §2.G), install discovery via `libraryfolders.vdf`/ACF, build identity via `buildid` + depot manifests on entitled lab accounts; GOG pulled forward to MVP+1 (7 of 13 portfolio titles, 5 certifiable DRM-free builds); Epic deferred indefinitely. SSA §4.C lab-automation mitigations added to the SPIKE-LEGAL-001 counsel checklist.

Evaluate:

- install discovery;
- authentication handoff;
- update/build identity;
- offline behavior;
- multiple library locations;
- launcher process complexity;
- 32-bit helper burden of the client itself (x64-purity of launcher processes, per ADR-0011);
- terms and partner posture;
- addressable candidate catalog.

**Decision criteria:** user value, integration reliability, legal clarity, automation, support burden.

### SPIKE-LAB-001 — Reproducible Mac/Windows runner

**Hypothesis:** A deterministic scene can run on Windows and Mac with exact artifact identity and comparable evidence.

**Prototype:**

- one D3D11 title;
- fixed save/input;
- structured lifecycle;
- frame capture and metrics;
- runner provenance;
- rerun variance;
- seeded regression.

**Pass evidence:**

- stable outcome and acceptable variance;
- exact evidence record;
- automated comparison identifies seeded visual/performance defect;
- total run cost measured.

### SPIKE-ROLLBACK-001 — Transactional generation lifecycle

Inject process termination/power failure at every stage:

```text
download → verify → publish CAS → materialize
→ prepare candidate → switch active reference → health window
→ retain/collect old generation
```

**Pass invariant:** active reference is previous or complete candidate; saves remain byte-identical; operation resumes or rolls back.

### SPIKE-DIAG-001 — Support reproduction

Seed failures in:

- profile mismatch;
- wrong provider;
- shader compiler crash;
- permission;
- corrupt cache;
- memory pressure;
- guest crash.

Have an engineer with only the privacy-filtered bundle reproduce/classify them. Measure success and missing evidence.

### SPIKE-PRIV-001 — Minimal telemetry set

Determine which fields are truly required for:

- severe regression detection;
- rollback health;
- security/update integrity;
- product funnel;
- support.

Run privacy review, re-identification analysis, storage/cost estimate, and user comprehension test.

## 5. P1 native-service spikes

### SPIKE-MEDIA-001 — Media Foundation bridge (modern codecs only)

- enumerate codecs actually used by modern-baseline catalog candidates (expected: H.264/AAC and game-bundled codecs such as Bink);
- prototype VideoToolbox/AudioToolbox-backed decode for H.264/AAC;
- test timestamps, seeking, cutscene sync;
- define unsupported protected media;
- confirm no shortlisted title requires a WMV/VC-1/legacy pipeline (excluded by ADR-0011);
- complete codec/patent distribution review for the VideoToolbox-only decode posture (no bundled software decoders).

### SPIKE-INPUT-001 — Controller and raw input

- XInput/GameInput-class controllers, Raw Input, HID (certified scope; DirectInput-era paths remain upstream-Wine behavior, permanently uncertified per ADR-0011);
- controller hotplug/rumble/gyro;
- relative mouse and high polling;
- focus capture;
- Steam Input coexistence;
- end-to-end latency.

### SPIKE-AUDIO-001 — XAudio2/WASAPI over CoreAudio

- timing and buffers;
- channel layout;
- device change/Bluetooth;
- capture;
- underrun measurement;
- voice chat.

### SPIKE-DISPLAY-001 — Presentation/HDR/VRR

- CAMetalLayer/window lifecycle;
- 60/120/VRR pacing;
- SDR/HDR/color spaces;
- resize/display move;
- fullscreen-like behavior;
- latency and frame queue.

### SPIKE-STORAGE-001 — DirectStorage-oriented path

- identify real game API use;
- prototype read/decompression/Metal upload path;
- measure copies and CPU;
- decide whether it belongs before GA.

## 6. P1 commercial and partnership spikes

### SPIKE-PRICE-001 — Willingness to pay

Interview and test pricing with:

- Mac gamers with active Windows libraries;
- enthusiast compatibility users;
- users comparing cloud gaming or a gaming PC;
- prospective annual subscribers.

Test:

- free compatibility scan;
- paid certified catalog;
- support/diagnostics value;
- monthly versus annual;
- catalog expectations;
- offline entitlement expectations.

### SPIKE-PUB-001 — Publisher design partner

Find one title with:

- engaged technical team;
- no hard kernel blocker;
- useful pre-release build;
- representative engine;
- willingness to share symbols/test hooks.

Validate report usefulness, turnaround, and path to public certification.

### SPIKE-AC-001 — Anti-cheat vendor integrity concept

Without promising support:

- document runtime measurement;
- Certified/Custom distinction;
- challenge/freshness;
- attack model;
- vendor API/operational needs;
- privacy and failure behavior.

The output is a design-partner discussion package, not a bypass prototype.

## 7. Decision schedule

| Decision | Required spikes | Target gate |
| --- | --- | --- |
| Production CPU path | CPU-001, WINE-001 | End Phase 0 |
| MVP legal distribution | LEGAL-001 | Before external binary (partially closed — preliminary findings, counsel brief and pre-counsel assessment drafted; **qualified counsel still pending**) |
| First storefront | STORE-001 | **Decided** 23 Jul 2026 (D-019: Steam; GOG at MVP+1) |
| MVP game catalog | CATALOG-001, GFX-001, LAB-001 | Portfolio selected 23 Jul 2026 (D-020); GFX-001/LAB-001 validation by end Phase 0 |
| Runtime architecture go | ROLLBACK-001, DIAG-001 | End Phase 0/early Phase 1 |
| Metal12 architecture | M12-001/002/003/004 | Sequential vertical-slice gates |
| Telemetry default | PRIV-001 | Before external preview |
| Consumer pricing | PRICE-001 | Before public beta |
| Publisher portal priority | PUB-001 | Beta planning |
| Competitive integrity program | AC-001 + partner approval | GA/post-GA |

## 8. Spike acceptance rules

- A demo without measurement does not close a spike.
- A benchmark without correctness evidence does not close a runtime spike.
- One easy game does not validate a general path; workloads must be representative.
- Legal uncertainty cannot be converted into a technical assumption.
- A failed hypothesis is a successful spike when it produces a clear decision.
- Code produced by a spike is disposable unless it meets production standards.
- Results update the relevant ADR, risk, roadmap, and architecture documents.
