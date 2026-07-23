# Alloy

## Product Requirements Document

**Document version:** 1.0  
**Status:** Proposed product baseline  
**Date:** 20 July 2026  
**Product owner:** Head of Product  
**Technical owner:** CTO / Chief Architect  
**Primary audience:** founders, product, design, engineering, compatibility operations, security, publisher partnerships, support, and investors performing diligence  
**Related documents:** [Product strategy](01_PRODUCT_STRATEGY.md) · [UX specification](03_UX_AND_USER_JOURNEYS.md) · [Technical architecture](04_TECHNICAL_ARCHITECTURE.md) · [Certification](07_COMPATIBILITY_CERTIFICATION_SPEC.md) · [Roadmap](11_ROADMAP_TEAM_AND_DELIVERY.md)

---

## 1. Executive summary

Alloy is a Mac-gaming platform that runs supported Windows games on Apple-silicon Macs through a certified, reproducible compatibility runtime. It is not a general Windows application layer and it does not ask players to manage Wine prefixes, graphics backends, DLL overrides, registry keys, or command-line flags.

The product object is an **exact certified game runtime generation**:

```text
exact game build
+ launcher/storefront build and branch
+ host capability class
+ immutable runtime component set
+ signed per-process compatibility policy
+ cache compatibility epoch
+ test and certification evidence
```

The player experience is deliberately simple: discover a supported game, review an honest compatibility status, install it, and launch it. Behind that experience, the system isolates each game from global runtime changes, routes each Windows process to the correct CPU, graphics, synchronization, media, input, filesystem, and network providers, observes health and performance, and rolls back failed runtime updates without touching saves.

The initial commercial wedge is a narrow catalog of high-value single-player and cooperative games that can be made predictably excellent. Catalog breadth is secondary to reliability. Competitive multiplayer is offered only when the publisher and anti-cheat vendor explicitly enable and certify the runtime.

## 2. Product thesis

Cross-platform compatibility products have historically exposed an environment-management abstraction: a mutable prefix or bottle containing a partial Windows installation. That model is flexible, but it makes game support hard to reproduce, hard to explain, and risky to update.

Alloy uses a different abstraction:

> A supported title is a signed, independently versioned, continuously tested game runtime—not a user-maintained Windows environment.

The product can therefore make a stronger promise than “this might run”:

> This exact build is certified on this class of Mac through this exact runtime, with these known capabilities and limitations, and a safe rollback is available when any dependency changes.

## 3. Problem statement

### 3.1 Player problems

Mac players who attempt to run Windows games through compatibility layers commonly face:

- uncertain compatibility that changes after game, launcher, macOS, or runtime updates;
- manual choices between graphics backends and synchronization modes;
- launchers that require different behavior from the game process;
- shader compilation stutter, frame-pacing failures, long-session memory growth, input/audio/media edge cases, and opaque crashes;
- mutable environments that become impossible to reproduce after months of updates and experiments;
- confusing support instructions involving prefixes, registry edits, environment variables, DLL overrides, and cache deletion;
- unsupported anti-cheat or DRM presented without a clear distinction between technical and publisher-policy limitations;
- fear that repair, rollback, or uninstall will damage saves.

### 3.2 Engineering and support problems

Compatibility teams need to identify whether a regression came from the game, launcher, storefront, macOS, Wine, CPU translation, graphics translation, a native service, a profile rule, or stale derived data. Without immutable identities and automated reference tests, support becomes a sequence of manual guesses.

### 3.3 Publisher problems

Publishers want access to Mac users without funding and maintaining a full native port for every title. They need objective pre-release results, precise failure classification, controlled anti-cheat integration, and a support channel that does not require them to endorse an opaque, modifiable runtime.

## 4. Vision and positioning

### 4.1 Vision

Make a meaningful Windows gaming library feel like a first-class, dependable Apple-silicon gaming catalog.

### 4.2 Positioning

Alloy is positioned as:

> **A certified Apple-silicon gaming runtime for supported Windows game builds.**

It is not positioned as:

- a general Windows application compatibility suite;
- a graphical Wine-prefix manager;
- a Windows virtual machine;
- a launcher that wraps an unchanged third-party translation stack;
- a universal anti-cheat bypass;
- a promise that every Windows game works on day one.

### 4.3 Product principles

1. **Reliability over catalog count.** Ten titles that remain working after updates are more valuable than thousands marked “possibly playable.”
2. **Exact evidence over reputation.** Compatibility status is tied to build, host, runtime, and test evidence.
3. **One-click by default.** Compatibility complexity is owned by the platform.
4. **Explainability without jargon.** Players see what changed, what is affected, and what action is safe.
5. **Atomic change and rollback.** No global runtime update can silently change every installed title.
6. **Mac-native optimization.** Apple GPU, unified memory, Metal, CoreAudio, input, storage, display, and macOS synchronization are first-class.
7. **Honest boundaries.** Unsupported kernel anti-cheat, DRM, protected media, or device-driver requirements are not disguised as ordinary bugs.
8. **Local resilience.** Cloud services improve distribution and certification but are not on the installed launch hot path.
9. **Privacy by construction.** Supportability does not require broad file access or gameplay recording.
10. **Publisher trust.** Certified integrity and evidence are product capabilities, not afterthoughts.

## 5. Goals

| ID | Goal | Product outcome | Primary measure |
| --- | --- | --- | --- |
| G-01 | Deterministic certified launch | A supported player does not configure compatibility internals | Certified launch-success rate |
| G-02 | Reliable updates | Game and runtime changes are detected, retested, and safely rolled out | Severe regression rate and rollback success |
| G-03 | Mac-native performance | Frame pacing, shader behavior, memory, input, and audio meet title-specific gates | Certification performance scorecard |
| G-04 | Reproducible support | Support can recreate the exact failing state | Reproduction rate from diagnostic bundle |
| G-05 | Safe data lifecycle | Runtime operations never endanger saves by default | Save-loss incidents |
| G-06 | Credible support matrix | Status reflects exact evidence, not community anecdotes | Stale/incorrect certification incidents |
| G-07 | Sustainable platform | Runtime, profile, and lab systems scale without one-off manual installs | Engineer hours per certified update |
| G-08 | Publisher channel | Publishers can evaluate and improve compatibility before release | Partner pilots and certified pre-release builds |

## 6. Non-goals

The first product does not:

- support arbitrary Windows productivity or enterprise applications;
- emulate the Windows kernel or load Windows kernel drivers;
- require a Windows installation or license for normal execution;
- guarantee universal day-zero compatibility;
- bypass DRM, ownership checks, anti-cheat, or protected-media policy;
- claim proprietary upscalers or frame-generation systems are interchangeable;
- support Intel Macs;
- support 32-bit (x86) game executables — 32-bit is limited to auxiliary launcher/installer helper processes where a supported title requires one (ADR-0011);
- support titles whose primary renderer is Direct3D 9 or earlier, DirectDraw, or OpenGL (ADR-0011);
- support standalone wizard-style installers — installation is storefront-managed (ADR-0011);
- optimize for Mac App Store distribution;
- expose unsupported experimental modifications as equivalent to Certified Mode;
- make the cloud control plane mandatory for an already installed offline-capable game.

## 7. Target customers and jobs to be done

### 7.1 Primary persona: mainstream Mac gamer

**Context:** owns an Apple-silicon Mac, buys games through mainstream storefronts, and does not want to learn Wine terminology.

**Jobs:**

- “Tell me whether my exact game version works on my exact Mac.”
- “Install and launch it with no compatibility decisions.”
- “Keep it working when the game or macOS updates.”
- “Protect my saves and tell me what is safe to delete.”
- “Explain failures in ordinary language.”

### 7.2 Secondary persona: enthusiast

**Context:** accepts experimentation and mods but wants a reliable certified baseline.

**Jobs:**

- “Let me inspect active providers and workarounds.”
- “Let me create an isolated custom configuration.”
- “Let me return to a verified state instantly.”
- “Give me high-quality diagnostics instead of forum folklore.”

### 7.3 Internal persona: compatibility engineer

**Jobs:**

- “Reproduce an exact customer session.”
- “Compare Windows and Mac behavior.”
- “Bisect a regression across every changing component.”
- “Ship a narrowly scoped profile fix without destabilizing unrelated games.”
- “Know which workarounds can be retired.”

### 7.4 Partner persona: publisher or anti-cheat engineer

**Jobs:**

- “Test a Windows build on representative Macs before release.”
- “Receive specific, actionable compatibility evidence.”
- “Understand the runtime integrity model.”
- “Enable approved multiplayer without accepting undocumented injection.”
- “Know when an update invalidates certification.”

## 8. Product editions and operating modes

### 8.1 Certified Mode

Certified Mode is the default and highest-trust state. It uses:

- signed profiles and runtime metadata;
- verified immutable runtime layers;
- exact build selectors;
- locked process policy;
- approved provider versions;
- declared modifications state;
- current certification evidence;
- automatic rollback and health monitoring.

### 8.2 Custom Mode

Custom Mode is an isolated advanced-user state. It may allow alternate providers, environment settings, DLL behavior, patches, overlays, or mods. Entering it changes integrity state visibly and cryptographically. Custom changes never mutate the certified generation and can be discarded without touching saves.

### 8.3 Developer/Lab Mode

Developer/Lab Mode is for internal and approved partner systems. It exposes validation layers, traces, replay, experimental providers, unsigned local development profiles under a development trust root, and high-volume diagnostics. It is never distributed as the normal player experience.

## 9. Product scope by release

### 9.1 MVP / developer preview

The MVP proves the product architecture, not broad market coverage.

**Included:**

- Apple-silicon-only native client and runtime daemon;
- current supported macOS baseline expressed through host capabilities;
- one primary storefront integration with storefront-managed installation (no standalone wizard-installer support, per ADR-0011);
- 8–12 hand-selected certified games, weighted toward Direct3D 11;
- immutable runtime generations, content-addressed storage, transactional activation, and rollback;
- thin Wine fork and first production CPU provider;
- per-process policy applied before normal imports;
- D3D10/11 Metal-native provider;
- no bundled bootstrap D3D12 provider — GPTK/D3DMetal is non-redistributable for commercial products (SPIKE-LEGAL-001); GPTK use is lab/reference only, and D3D12 titles enter the catalog only via Metal12 (ADR-0006, ADR-0012);
- native input, audio, filesystem, windowing, and essential media paths;
- signed profile and runtime formats;
- local diagnostics and privacy-filtered support bundles;
- initial physical Mac lab and Windows reference runner;
- honest support status and known limitations;
- no kernel anti-cheat promise.

**Not included:**

- broad storefront coverage;
- first-party Metal12 feature completeness;
- competitive multiplayer certification;
- publisher self-service;
- automatic multi-dimensional bisection at full scale;
- advanced mod management;
- 32-bit game executables (permanent modern-baseline exclusion per ADR-0011, not a deferred tier).

### 9.2 Private beta

The private beta validates operational repeatability.

- 25–40 supported titles across multiple engines;
- at least two major storefront paths;
- candidate health windows and automatic rollback;
- continuous game/launcher update detection;
- expanded media, controller, HDR, and display coverage;
- host-class support matrix across representative Apple GPU and memory tiers;
- Custom Mode with hard isolation;
- performance regression gates;
- initial Metal12 title experiments;
- support tooling and incident playbooks.

### 9.3 Public beta

The public beta validates scale and user comprehension.

- 75–150 supported titles, subject to quality gates;
- stable catalog, compatibility status, and update messaging;
- release rings for profiles and runtime components;
- mature telemetry consent and privacy controls;
- automated regression clustering and partial bisection;
- publisher pilot portal;
- stronger accessibility and localization;
- defined customer-support response model.

### 9.4 General availability

GA requires a defensible proprietary platform, not merely a polished wrapper.

- owned Metal12 path certified for the agreed D3D12 launch subset;
- stable D3D11 and D3D12 catalogs with published quality criteria;
- independently promotable providers and per-title runtime generations;
- reproducible certification evidence and robust rollback;
- security, provenance, privacy, and incident-response gates;
- publisher integration and at least one approved anti-cheat/vendor pilot where feasible;
- production SLOs and cost controls.

## 10. Core user journeys

### 10.1 Discover, install, and launch a certified game

1. The client discovers an owned or locally installed game.
2. It fingerprints the exact storefront branch, game build, and launcher build.
3. It evaluates the host capability class.
4. It displays certification level, tested build, date, expected capabilities, limitations, and storage requirement.
5. The player selects **Install runtime** or **Play**.
6. Required signed objects download and verify; materialization is transactional.
7. On launch, the daemon compiles an immutable LaunchSpecification.
8. Each process receives its policy before normal Windows initialization.
9. The UI shows Running and exposes optional session health without compatibility jargon.
10. The session result updates only local health by default; optional telemetry follows consent.

### 10.2 Game updates before certification is ready

1. The storefront updates the game or launcher.
2. The fingerprint no longer matches the signed certification selector.
3. The title becomes **Certification stale** or **Update under test**.
4. Product policy may permit a provisional launch, preserve the last launchable build when the storefront allows it, or block a known-destructive state.
5. The lab automatically schedules impacted tests.
6. A new signed profile or certification record is promoted after evidence passes.

### 10.3 Runtime candidate regresses

1. A candidate runtime generation is activated for a canary cohort.
2. Health signals cross a severe-regression threshold or a local session fails its candidate health window.
3. The candidate is quarantined.
4. The local active reference returns to the last healthy generation.
5. Saves, settings, and game payload remain intact.
6. Diagnostics and artifact identities feed automated clustering and bisection.

### 10.4 Player creates a custom configuration

1. The player explicitly enters Custom Mode.
2. The client explains loss of certified guarantees and multiplayer implications.
3. Custom state is cloned or overlaid separately.
4. The player applies modifications.
5. The library and session clearly display Custom state.
6. **Reset to Certified** discards custom runtime state while retaining saves according to policy.

### 10.5 Support diagnosis

1. The player opens a failed session and selects **Create diagnostic report**.
2. The client shows a privacy preview.
3. A bundle includes runtime identity, process tree, provider selection, relevant logs, crash/hang data, and host pressure—not unrelated files.
4. The player can save locally or consent to upload.
5. Support resolves the same generation in a lab and runs the relevant scenario.
6. The resulting issue is classified to game, launcher, runtime component, host, profile, cache, permission, or unsupported protection technology.

## 11. Functional requirements

Requirements use **MUST**, **SHOULD**, and **MAY** normatively. Priority is P0 (release-blocking), P1 (important), or P2 (planned extension). Target is the earliest product stage at which the requirement is expected to be complete.

| ID | Area | Requirement | Priority | Target | Normative statement | Acceptance criterion |
| --- | --- | --- | --- | --- | --- | --- |
| CAT-001 | Catalog | Unified game identity | P0 | MVP | The client MUST represent each supported title with one canonical game identity and one or more storefront bindings. | The same title installed from two supported storefronts appears as one catalog entity with distinct install records and build fingerprints. |
| CAT-002 | Catalog | Exact build fingerprinting | P0 | MVP | The platform MUST identify the installed game and launcher builds using storefront manifest identifiers and/or cryptographic file fingerprints. | A launch specification cannot be certified when the required build selector does not match; the UI displays the mismatch and last certified build. |
| CAT-003 | Catalog | Transparent support status | P0 | MVP | Every discovered game MUST display a support state derived from signed certification evidence. | The UI distinguishes every status in the §14 model — including Untested and Quarantined — without using ambiguous green/yellow labels alone. |
| CAT-004 | Catalog | Known limitations | P0 | MVP | The game details view MUST expose known limitations, affected host classes, certification date, and exact tested build. | Limitations are available before installation and launch and are sourced from the active signed profile. |
| CAT-005 | Catalog | Update invalidation | P0 | Beta | The platform MUST detect when a game or launcher update no longer matches certified selectors. | Within one discovery cycle, the title is marked provisional or stale; the prior certification is not silently carried forward. |
| CAT-006 | Catalog | Offline catalog snapshot | P1 | Beta | The client SHOULD retain the last verified catalog, profile, and certification metadata needed to launch installed games offline. | Disconnecting the Mac from the network does not prevent launch of an installed title whose storefront authentication permits offline use. |
| INS-001 | Installation | One-click certified install | P0 | MVP | A player MUST be able to install a certified title without selecting Wine versions, DLL overrides, graphics backends, or prefix settings. | From a supported storefront binding, installation reaches Ready or a specific actionable failure state with no compatibility configuration dialog. |
| INS-002 | Installation | Transactional installation | P0 | MVP | Game runtime installation MUST be transactional and crash-consistent. | Power loss or process termination during download/materialization leaves no active partial generation and can resume without redownloading verified objects. |
| INS-003 | Installation | Content-addressed deduplication | P0 | MVP | Runtime components MUST be stored by cryptographic digest and shared safely across games. | Installing a second title that references identical verified layers does not duplicate those bytes; reference accounting prevents premature collection. |
| INS-004 | Installation | Separate persistent data | P0 | MVP | Save data and user settings MUST be stored outside immutable runtime generations and disposable caches. | Rolling back or deleting a runtime generation does not delete saves; backup/restore tests preserve byte-identical save payloads. |
| INS-005 | Installation | Disk-space planning | P0 | MVP | Before installation or update, the client MUST estimate download, temporary, final, and rollback-retention storage requirements. | The operation refuses safely when space is insufficient and identifies reclaimable caches separately from saves and game payload. |
| INS-006 | Installation | Dependency provenance | P0 | Beta | Every bundled or installed redistributable MUST have an explicit source, digest, license gate, and install mode. | A release build cannot promote a dependency with missing provenance or unapproved redistribution status. |
| INS-007 | Installation | Atomic generation activation | P0 | MVP | Activating a runtime update MUST be an atomic reference change with a known rollback generation. | A failed candidate health window automatically returns the game to the last healthy generation without modifying saves. |
| INS-008 | Installation | Storefront-managed payload coexistence | P1 | Beta | The runtime SHOULD coexist with storefront ownership, verification, and update workflows rather than copying or bypassing them. | Storefront repair/update operations remain functional and the runtime re-fingerprints resulting builds. |
| INS-009 | Installation | Uninstall safety | P0 | MVP | Uninstall MUST clearly separate removal of runtime layers, game payload, caches, settings, and saves. | The default uninstall preserves saves; destructive choices require explicit confirmation and report affected paths and cloud-save state. |
| RUN-001 | Runtime | Deterministic launch specification | P0 | MVP | Every session MUST be created from an immutable LaunchSpecification containing exact game, launcher, host, runtime, profile, and cache epochs. | The session record can be exported and resolved to the same component digests in the lab. |
| RUN-002 | Runtime | Per-process policy before imports | P0 | MVP | CPU, graphics, synchronization, DLL, service, filesystem, and network policy MUST be resolved before normal Windows module initialization. | A launcher and its game executable can use different graphics and synchronization providers in the same session, verified by trace. |
| RUN-003 | Runtime | Thin upstream-oriented Wine fork | P0 | MVP | The Wine fork MUST remain rebasing-friendly and expose stable provider hooks instead of embedding title-specific behavior in generic code. | All downstream patches have an owner, upstream status, test, and maximum-age review; profile workarounds contain no arbitrary shell code. |
| RUN-004 | Runtime | ARM64-native host | P0 | MVP | All first-party host processes MUST execute as ARM64 Mach-O binaries on Apple silicon. | Release validation finds no required x86_64 host binary; guest x86/x64 execution occurs only through an approved execution provider. |
| RUN-005 | Runtime | CPU execution provider abstraction | P0 | MVP | x86/x64 execution MUST be behind a versioned provider interface supporting at least a FEX/ARM64EC production path and an optional bootstrap/reference path. | The same test binary can be run through each enabled provider, and provider selection is recorded per process. |
| RUN-006 | Runtime | Graphics provider abstraction | P0 | MVP | Direct3D, Vulkan, and legacy graphics MUST be selected through explicit versioned providers with no silent fallback in Certified Mode. | Provider identity and capability mask appear in session diagnostics; a missing required provider produces a deterministic pre-launch failure. |
| RUN-007 | Runtime | D3D10/11 Metal path | P0 | MVP | The initial certified Direct3D 10/11 path SHOULD use a maintained Metal-native provider derived from DXMT or equivalent. | The provider passes the defined D3D10/11 conformance subset and certification scenarios for the MVP catalog. |
| RUN-008 | Runtime | Owned D3D12-to-Metal path | P0 | GA | The strategic Direct3D 12 path MUST be a first-party controlled Metal-native implementation with independent release, diagnostics, and capability management. | At GA, at least the target D3D12 feature subset is implemented without a Vulkan intermediary and certifies the agreed launch catalog. |
| RUN-009 | Runtime | Adaptive synchronization | P1 | Beta | The runtime SHOULD select measurable Windows synchronization implementations per process and profile. | Wait latency and blocked time are exposed by primitive and call site; the certified policy is chosen from benchmark evidence. |
| RUN-010 | Runtime | Unified-memory budgeting | P0 | Beta | The graphics runtime MUST expose stable guest memory budgets and manage Metal resources under real host pressure. | Long-session tests on every supported memory class avoid unbounded growth, preserve a configured headroom floor, and recover or fail gracefully. |
| RUN-011 | Runtime | Native service bridges | P0 | Beta | Input, audio, media, networking, filesystem, windowing, and presentation MUST use versioned native-service bridges with process policy. | Service provider identity is recorded; required controller, audio, cutscene, focus, and display scenarios pass per certified title. |
| RUN-012 | Runtime | No privileged kernel dependency | P0 | MVP | The default product MUST NOT install a kernel extension or persistent root daemon. | A clean install and certified launch succeed under a standard user account with only documented user-approved permissions. |
| CMP-001 | Compatibility | Signed declarative profiles | P0 | MVP | All Certified Mode compatibility behavior MUST come from a signed, schema-valid profile and signed runtime metadata. | A modified, expired, unsigned, or schema-invalid profile is rejected before launch and cannot be mislabeled Certified. |
| CMP-002 | Compatibility | Deterministic policy precedence | P0 | MVP | Process-rule matching and conflict resolution MUST be deterministic across client and lab implementations. | Golden fixtures produce byte-identical compiled policy snapshots across supported builds. |
| CMP-003 | Compatibility | Scoped workaround lifecycle | P0 | Beta | Every workaround MUST include scope, reason, owner, test evidence, introduced revision, and review or expiry condition. | A profile cannot promote to stable with an unowned or untested workaround; expired workarounds trigger recertification. |
| CMP-004 | Compatibility | Continuous certification | P0 | Beta | Certified titles MUST be retested after relevant changes to game, launcher, macOS, runtime components, profiles, or host capability classes. | The control plane schedules impacted test plans and prevents stable promotion until required evidence is current. |
| CMP-005 | Compatibility | Windows reference oracle | P0 | Beta | The lab MUST support deterministic Windows reference runs for behavior and visual comparison. | For each certified graphics scenario, the evidence record links Mac and Windows traces, outputs, and tolerances. |
| CMP-006 | Compatibility | Automated regression bisection | P1 | GA | The analysis platform SHOULD bisect regressions across game, launcher, profile, Wine, CPU, graphics, service, macOS, and cache dimensions where artifacts are available. | For seeded regressions, the system identifies the causal change or narrows it to one component class within the defined compute budget. |
| CMP-007 | Compatibility | Certification expiry | P0 | Beta | Certification MUST expire or become stale when its exact build or required matrix coverage is no longer valid. | The client never presents stale evidence as current and explains whether launch is blocked, provisional, or allowed with warning. |
| CMP-008 | Compatibility | Unknown executable containment | P0 | MVP | Unknown child processes MUST receive a conservative default policy and MUST NOT inherit unrestricted host access implicitly. | A previously unseen executable is logged, isolated, and cannot expand drive or network grants beyond the session policy. |
| CMP-009 | Compatibility | Certified and Custom separation | P0 | Beta | Certified Mode and Custom Mode MUST use visibly and cryptographically distinct state. | User modifications create or switch to Custom Mode; returning to Certified Mode restores a verified generation without mixing modified files. |
| CMP-010 | Compatibility | Support matrix by host class | P0 | Beta | Certification MUST identify supported macOS builds, Apple GPU families, and memory classes. | A host outside the tested selector receives an accurate untested/unsupported state rather than inheriting certification by model-name approximation. |
| CMP-011 | Compatibility | Launcher containment | P1 | Beta | Launcher and updater changes SHOULD be isolated from the game process through per-process policy and build selectors. | A launcher update can be quarantined or assigned a different provider without changing the pinned game runtime. |
| CMP-012 | Compatibility | Anti-cheat honesty | P0 | MVP | Competitive multiplayer MUST be marked supported only with explicit publisher and anti-cheat vendor enablement and matching certified integrity evidence. | Titles requiring unsupported kernel drivers are blocked or labeled unsupported; no runtime code attempts covert circumvention. |
| DIA-001 | Diagnostics | Stable session correlation | P0 | MVP | Every operation and session MUST have stable correlation identifiers spanning client, daemon, guest processes, providers, and optional cloud ingest. | A support bundle can reconstruct the full process tree and component identities from one session ID. |
| DIA-002 | Diagnostics | Structured logs and errors | P0 | MVP | First-party components MUST emit structured events with stable error domains and machine-readable causes. | Top-level UI errors map to one or more correlated events without requiring free-text parsing. |
| DIA-003 | Diagnostics | Privacy-filtered bundle | P0 | MVP | The client MUST generate a local diagnostic bundle with preview, redaction, and explicit upload consent. | The preview lists included data classes; default redaction removes secrets, personal paths, chat content, and unrelated files. |
| DIA-004 | Diagnostics | Crash capture | P0 | MVP | Native and guest crashes MUST capture component versions, process policy, module lists, and available symbols without collecting game assets. | Seeded native and guest crashes create symbolicated reports for first-party frames and known guest modules. |
| DIA-005 | Diagnostics | Hang detection | P1 | Beta | The runtime SHOULD detect launch and in-session hangs using health deadlines, heartbeat, and wait-state evidence. | Seeded deadlocks produce a bounded diagnostic snapshot and do not leave orphaned session processes. |
| DIA-006 | Diagnostics | Performance telemetry | P0 | Beta | The runtime MUST measure frame-time percentiles, shader/PSO stalls, CPU translation cost, synchronization waits, memory pressure, and device-loss events where technically available. | Lab runs emit a versioned metric set tied to exact scenario and component identities. |
| DIA-007 | Diagnostics | Explain active policy | P0 | Beta | Players and support engineers MUST be able to see which providers and significant workarounds are active and why. | The game details/session view lists process-specific backend choices and references human-readable workaround descriptions. |
| DIA-008 | Diagnostics | Local-first support | P1 | Beta | Common installation, launch, cache, permission, and signature failures SHOULD be diagnosable locally without mandatory cloud access. | The client supplies a remediation action or precise support code for each defined P0 failure class. |
| DIA-009 | Diagnostics | Telemetry controls | P0 | MVP | Telemetry beyond essential security/update health MUST be opt-in or governed by explicit user settings and regional policy. | Changing telemetry level takes effect for new sessions, is visible, and does not disable local diagnostics. |
| DIA-010 | Diagnostics | Evidence provenance | P0 | Beta | Lab evidence and release decisions MUST retain source artifact digests, test-plan versions, runner identities, and comparison tolerances. | A certification record can be independently traced to immutable inputs and signed results. |
| UX-001 | Experience | Native library | P0 | MVP | The primary client MUST present installed, available, unsupported, and recently played games in a native macOS library. | A player can find and launch an installed certified game in no more than two primary actions from the library. |
| UX-002 | Experience | Actionable lifecycle states | P0 | MVP | Install, update, verify, launch, degraded, rollback, and failure states MUST be explicit and recoverable. | Each blocking state displays cause, affected component, safe next action, and whether saves are at risk. |
| UX-003 | Experience | Permissions explanation | P0 | MVP | The product MUST request only scoped macOS permissions and explain why each is needed at the moment of use. | Denied permissions produce a recoverable flow; the client shows and revokes active folder grants. |
| UX-004 | Experience | Controller-first launch | P1 | Beta | Certified controller-oriented games SHOULD be launchable and navigable with a supported controller after the client is open. | The defined controller test path reaches gameplay without requiring mouse interaction except for unavoidable third-party authentication. |
| UX-005 | Experience | Save visibility and protection | P0 | MVP | The client MUST show whether saves are local, backed up, or managed by a storefront cloud where detectable. | Before destructive actions, the user sees save status and can open the save location or create a local backup. |
| UX-006 | Experience | Compatibility change messaging | P0 | Beta | When support status changes because of an upstream update, the client MUST explain what changed and available choices. | The message distinguishes game update, launcher update, macOS update, runtime regression, and expired certification. |
| UX-007 | Experience | Custom Mode guardrails | P1 | Beta | Advanced controls MUST be available only in an explicitly entered Custom Mode with clear support consequences and reset path. | A user can export custom settings, reset to certified state, and cannot accidentally alter a certified generation. |
| UX-008 | Experience | Accessibility | P0 | Beta | The native client MUST support VoiceOver, keyboard navigation, scalable text, sufficient contrast, and reduced-motion settings. | Critical install, launch, error, and permission flows pass the project accessibility checklist and automated audits. |
| UX-009 | Experience | Localization-ready content | P1 | Beta | UI strings, compatibility explanations, and error messages SHOULD be localization-ready and separate technical codes from user text. | No user-facing sentence is constructed from untranslatable fragments; layout handles defined expansion factors. |
| UX-010 | Experience | No compatibility jargon by default | P0 | MVP | Default flows MUST avoid exposing Wine prefixes, DLL override syntax, environment variables, or backend acronyms as required user decisions. | Usability participants complete supported installation and launch without receiving compatibility-engineering instruction. |
| SEC-001 | Security | Signed update chain | P0 | MVP | Runtime artifacts, profiles, and release metadata MUST be verified through a role-separated signed update chain with rollback and freeze protection. | Clients reject tampered, expired, replayed, or unauthorized metadata and retain a safe installed generation. |
| SEC-002 | Security | Least-privilege filesystem | P0 | MVP | Certified sessions MUST receive a brokered drive view and MUST NOT map the user's host root by default. | Guest attempts outside granted roots fail; security tests confirm canonicalization, symlink, case, and traversal defenses. |
| SEC-003 | Security | W^X JIT discipline | P0 | MVP | CPU translation and shader/runtime JIT paths MUST maintain writable-xor-executable memory and use supported macOS entitlements and mappings. | Runtime assertions and security tests find no page that is simultaneously writable and executable in production mode. |
| SEC-004 | Security | Secret isolation | P0 | MVP | Storefront tokens, credentials, and diagnostic encryption keys MUST be kept out of profiles, logs, and guest-readable general storage. | Secrets are stored in approved keychain or scoped service storage; scanning release logs and bundles finds no seeded credentials. |
| SEC-005 | Security | Guest-host parser hardening | P0 | Beta | All guest-controlled IPC, shader, media, input, and file metadata parsers MUST be bounded, fuzzed, and versioned. | Security release gates include corpus coverage and no unresolved critical parser findings. |
| SEC-006 | Security | Certified integrity attestation | P1 | GA | Competitive Certified sessions SHOULD expose a signed measurement of runtime, profile, provider, and modification state suitable for approved vendor verification. | The vendor-facing result distinguishes certified, custom, tampered, and unknown state and is resistant to local replay within the threat model. |
| SEC-007 | Security | Supply-chain provenance | P0 | Beta | Every shipped first- and third-party component MUST have source revision, build recipe, SBOM, license identity, and attestation. | Stable promotion fails when required provenance or vulnerability review is missing. |
| SEC-008 | Security | Mod isolation | P1 | Beta | Mods and overlays MUST be treated as untrusted modifications and isolated from Certified Mode. | Enabling a modification changes integrity state before launch and preserves an unmodified certified rollback target. |
| SEC-009 | Security | Security response | P0 | Beta | The organization MUST support artifact/profile revocation, signing-key rotation, emergency rollback, and client notification. | A tabletop and technical drill revokes a seeded compromised target without blocking safe offline launches unnecessarily. |
| SEC-010 | Security | No DRM or anti-cheat circumvention | P0 | MVP | The product MUST NOT include features whose purpose is to bypass ownership checks, protected media, DRM policy, or anti-cheat enforcement. | Security and legal review is mandatory for protection-related compatibility changes; unsupported states are surfaced honestly. |
| PUB-001 | Publisher | Pre-release build ingestion | P1 | GA | Approved publishers SHOULD be able to submit pre-release builds, symbols, and test instructions into an isolated workspace. | Publisher artifacts are tenant-isolated, access-audited, retention-controlled, and selectable by certification jobs. |
| PUB-002 | Publisher | Compatibility report | P1 | GA | Publishers SHOULD receive a report covering functional results, performance, visual differences, known limitations, and causal subsystem. | The report links each finding to exact builds, host classes, scenarios, traces, and recommended remediation. |
| PUB-003 | Publisher | Profile review workflow | P1 | GA | Publishers SHOULD be able to review title-specific capability masks and workarounds before stable promotion where contracts require it. | Comments, approvals, supersession, and signer identity are retained in the release audit trail. |
| PUB-004 | Publisher | Symbols and privacy | P1 | GA | Publisher symbols and protected builds MUST be processed under explicit access and retention policy. | Only authorized jobs and engineers can access scoped assets; client diagnostic bundles do not redistribute publisher symbols. |
| PUB-005 | Publisher | Anti-cheat enablement package | P1 | GA | The platform SHOULD provide approved vendors with runtime identity, integrity measurements, test results, and documented compatibility hooks. | A partner can enable a title without accepting an undocumented general-purpose process injection surface. |
| PUB-006 | Publisher | Release notification | P2 | Post-GA | Publishers MAY receive early warning when game or launcher changes invalidate certification or degrade measured performance. | Configured contacts receive a deduplicated report with impacted builds and evidence links. |
| PUB-007 | Publisher | Native optimization adapters | P2 | Post-GA | The platform MAY expose documented optional adapters for MetalFX, media, input, storage, and telemetry integrations. | Each adapter has a versioned SDK, compatibility contract, sample, and fallback behavior. |
| PUB-008 | Publisher | No mandatory source-code port | P1 | GA | The publisher onboarding path SHOULD deliver useful compatibility results from an existing Windows build without requiring a native Mac port. | A partner can complete initial certification evaluation using binaries, symbols where available, and test accounts/instructions. |

## 12. Non-functional requirements

The numerical values below are planning targets. Title-specific certification may set stricter or different thresholds where the game, display mode, or host class requires it.

| ID | Quality area | Priority | Target | Requirement | Verification |
| --- | --- | --- | --- | --- | --- |
| NFR-PERF-001 | Launch orchestration | P0 | MVP | For an already installed game with no storefront login prompt, first-party orchestration overhead from click to guest root-process start SHOULD be ≤ 3 seconds at p95 on the minimum supported host; game/launcher initialization time is measured separately. | Performance benchmark |
| NFR-PERF-002 | Frame pacing | P0 | Beta | Certified scenarios MUST define title-specific frame-time gates using median, p95, p99, and stutter-event thresholds; average FPS alone cannot satisfy a gate. | Lab benchmark |
| NFR-PERF-003 | Shader stutter | P0 | Beta | Stable certification MUST bound synchronous shader/PSO compilation stalls and include warm- and cold-cache measurements. | Graphics benchmark |
| NFR-PERF-004 | Memory headroom | P0 | Beta | Each supported memory class MUST retain an empirically defined host headroom floor during certified endurance scenarios or terminate gracefully before system-wide pressure collapse. | Endurance test |
| NFR-PERF-005 | Input latency | P1 | GA | Input-to-present latency SHOULD be measured for controller and mouse scenarios; title certification may define maximum regression versus the project baseline. | Latency lab |
| NFR-PERF-006 | Cache discipline | P1 | Beta | Derived caches MUST have version keys, quotas, recency policy, and safe eviction; cache growth cannot be unbounded. | Storage endurance |
| NFR-REL-001 | Local availability | P0 | MVP | Installed certified offline launch orchestration targets 99.9% local availability excluding required third-party storefront availability and game defects. | SLO review |
| NFR-REL-002 | Crash consistency | P0 | MVP | Install, activation, rollback, and garbage-collection operations MUST recover after process death or power interruption without invalid active references. | Fault injection |
| NFR-REL-003 | Save preservation | P0 | MVP | Runtime install, update, rollback, repair, and uninstall defaults MUST cause zero save deletion; this is a release invariant. | Recovery suite |
| NFR-REL-004 | Automatic rollback | P0 | Beta | A severe candidate regression detected during the configured health window MUST quarantine the candidate and restore the last healthy generation on the next safe launch. | Canary simulation |
| NFR-REL-005 | Offline continuity | P1 | Beta | Cloud control-plane outage MUST NOT block launch of a locally installed, locally verified generation when third-party authentication permits it. | Chaos test |
| NFR-REL-006 | Idempotency | P0 | MVP | All mutating local and cloud operations MUST accept or derive idempotency identifiers and safely tolerate retries. | Contract test |
| NFR-SEC-001 | Code signing | P0 | MVP | Every first-party executable, framework, helper, and shipped runtime artifact MUST be signed and verified; the macOS application must be notarized. | Release gate |
| NFR-SEC-002 | Privilege | P0 | MVP | The stable client MUST operate without a kernel extension, persistent root daemon, or broad full-disk-access requirement. | Install audit |
| NFR-SEC-003 | Vulnerability response | P0 | Beta | Critical remotely exploitable vulnerabilities in first-party or shipped components require immediate release halt, target revocation where applicable, and an emergency update objective defined by incident policy. | Incident drill |
| NFR-SEC-004 | Cryptographic agility | P1 | GA | Metadata and artifact verification formats MUST support algorithm and key rotation without reinstalling the product. | Protocol test |
| NFR-PRIV-001 | Data minimization | P0 | MVP | Essential operation MUST not require collection of gameplay video, save contents, chat content, document contents, or unrelated file names. | Privacy review |
| NFR-PRIV-002 | Consent | P0 | MVP | Diagnostic upload MUST require explicit consent and a preview; telemetry settings must be understandable and revocable. | UX/privacy test |
| NFR-PRIV-003 | Retention | P0 | Beta | Every telemetry and diagnostic data class MUST have a documented purpose, retention period, access policy, and deletion mechanism. | Data governance audit |
| NFR-PRIV-004 | Regional controls | P1 | GA | Data collection and processing behavior MUST be configurable by legal region and contract without changing runtime correctness. | Policy test |
| NFR-OPS-001 | Observability | P0 | MVP | All first-party services and runtime processes MUST emit correlated health, error, and version information sufficient to distinguish game, launcher, profile, runtime, host, and service failures. | Operational readiness review |
| NFR-OPS-002 | Release rings | P0 | Beta | Profiles and runtime components MUST promote independently through development, lab, canary, stable, and quarantined states. | Release pipeline test |
| NFR-OPS-003 | Reproducibility | P0 | Beta | Release artifacts SHOULD be reproducible; at minimum, provenance must bind source, recipe, builder, inputs, and resulting digest. | Supply-chain audit |
| NFR-OPS-004 | Auditability | P0 | Beta | Certification, signing, promotion, revocation, and publisher-access decisions MUST be attributable to authenticated actors or automated identities. | Audit log review |
| NFR-OPS-005 | Support bundle success | P1 | Beta | At least 95% of supported-runtime native frames and known guest modules in submitted bundles SHOULD symbolicate when corresponding symbols are available. | Support KPI |
| NFR-OPS-006 | Cost controls | P1 | GA | Lab scheduling, telemetry sampling, artifact retention, and CDN delivery MUST expose budgets and quotas so a title or malformed client cannot create unbounded cloud cost. | Load/cost test |
| NFR-EVO-001 | Schema compatibility | P0 | MVP | Profile, manifest, event, and API schemas MUST use explicit versions and define backward/forward compatibility rules. | Contract test |
| NFR-EVO-002 | Provider ABI | P0 | Beta | CPU, graphics, and native-service provider interfaces MUST be versioned and permit side-by-side provider generations for certification and rollback. | ABI test |
| NFR-EVO-003 | Upstream rebase | P1 | Beta | The project SHOULD be able to evaluate and rebase to a new upstream Wine generation without forcing simultaneous promotion for every certified game. | Release exercise |
| NFR-EVO-004 | Host capability model | P0 | Beta | New macOS and Apple GPU generations MUST enter through capability metadata and lab evidence rather than scattered model-name conditionals. | Resolver test |
| NFR-ACC-001 | Accessibility | P0 | Beta | Critical native-client flows MUST meet the project's adopted accessibility standard, including VoiceOver, keyboard, text scaling, contrast, and reduced motion. | Accessibility audit |
| NFR-LOC-001 | Localization | P1 | Beta | Product UI, errors, support status, and profile-authored explanations MUST support localization and pluralization without changing machine-readable codes. | Localization test |

## 13. Information architecture and product surfaces

The native client contains the following top-level surfaces:

| Surface | Purpose | Required states |
| --- | --- | --- |
| Library | Discover and launch games | Installed, available, unsupported, update under test, stale, custom, failed |
| Game details | Explain exact support and manage lifecycle | Certification, build identity, limitations, host coverage, install/update/play/rollback |
| Downloads and storage | Manage transactional operations and disk use | Queued, downloading, verifying, materializing, ready, paused, failed, reclaimable |
| Session | Show launch progress and health | Resolving, preparing, authenticating, starting, running, degraded, ended, failed |
| Diagnostics | Explain and package evidence | Summary, technical details, privacy preview, remediation, export/upload |
| Settings | Accounts, storage, permissions, telemetry, updates | Per-setting explanation and safe defaults |
| Custom Mode | Isolated advanced configuration | Not created, active, modified, resettable, incompatible |
| Publisher portal | Partner builds and evidence | Submission, test plan, running, findings, approved, expired |

Detailed interaction requirements are in [03_UX_AND_USER_JOURNEYS.md](03_UX_AND_USER_JOURNEYS.md).

## 14. Compatibility status model

| Status | Meaning | Launch policy |
| --- | --- | --- |
| Unsupported | Known hard blocker or outside product scope | Block or allow only in clearly unsupported Custom Mode |
| Untested | No valid evidence for the exact build/host | Optional Custom/experimental launch |
| Experimental | Engineering evidence exists; stability is not promised | Explicit warning; no certified guarantee |
| Launches | Installation and initial launch pass | Limited support; gameplay not certified |
| Playable | Defined gameplay path passes with disclosed limitations | Supported for the tested path |
| Certified | Functional, performance, reliability, save, input/audio/media, and update gates pass | Default one-click launch |
| Competitive Certified | Certified plus explicit publisher/anti-cheat integrity enablement | Approved multiplayer path |
| Certification stale | Prior evidence does not match current build or has expired | Explain cause; provisional or blocked by title policy |
| Quarantined | A severe regression or security issue is active | Block candidate; use safe rollback if available |

**Derived and orthogonal states.** "Update under test" (a UI presentation of Certification stale while a scheduled retest is pending) and "Custom" (a mode indicator, orthogonal to certification status) are presentation states defined in [03_UX_AND_USER_JOURNEYS.md](03_UX_AND_USER_JOURNEYS.md). The nine statuses above are the canonical certification states.

The product MUST display both the level and the exact scope: build, host classes, tested scenarios, date, and limitations.

## 15. Success metrics

### 15.1 North-star metric

**Certified Successful Play Hours (CSPH):** play hours from exact certified sessions that reached gameplay, remained crash-free for the measurement interval, and did not encounter a severe platform-class failure.

This avoids rewarding catalog entries or launches that do not produce a usable experience.

### 15.2 Product health metrics

| Metric | Initial target direction |
| --- | --- |
| Certified launch success | ≥ 98% excluding explicit third-party authentication outages |
| Crash-free certified sessions | ≥ 99% for the defined 60-minute window, title-adjusted |
| Candidate rollback success | ≥ 99.9% without save impact |
| Save-loss incidents caused by runtime lifecycle | Zero |
| Severe regression escape rate | Declining release over release |
| Median time from detected top-catalog regression to causal component | < 24 hours after lab reproduction |
| Median time to safe mitigation for top-catalog regression | < 48 hours, including rollback/profile mitigation |
| Support reproduction from complete bundle | ≥ 80% initially, improving toward 95% |
| One-click task completion for supported install/launch | ≥ 90% in usability testing |
| Unknown/stale status shown as current certification | Zero accepted incidents |
| Cache/storage complaints per active installation | Monitored by memory/storage class and release |
| Custom-to-certified reset success | ≥ 99.9% |

Targets become contractual only after baselines from alpha telemetry and lab runs.

## 16. Analytics and event requirements

The minimum local event model includes:

- catalog discovery and build fingerprint result;
- certification resolution result;
- installation operation lifecycle;
- runtime generation activation and rollback;
- launch state transitions;
- process identity and selected policy;
- provider versions and feature masks;
- health-check outcomes;
- crash, hang, device-loss, memory-pressure, audio-underrun, and input-device events;
- session duration and clean exit;
- user-facing remediation action;
- diagnostic bundle creation and optional upload consent;
- Custom Mode state changes.

Events use stable machine-readable codes. Personally identifying data, credentials, save contents, chat, gameplay video, and unrelated file paths are excluded by default. The complete data-class policy is in [09_SECURITY_PRIVACY_THREAT_MODEL.md](09_SECURITY_PRIVACY_THREAT_MODEL.md).

## 17. Business and commercial assumptions

Commercial hypotheses — subscription structure, free-tier design, publisher revenue potential, and reseller posture — are owned by [01_PRODUCT_STRATEGY.md](01_PRODUCT_STRATEGY.md) §10. The following bind product design and are retained here as constraints on implementation, not as business strategy:

- Offline installed launch must not depend on a live Alloy subscription check more frequently than the final commercial policy requires; entitlement design must preserve reasonable offline use.
- Compatibility status MUST never be paywalled in a misleading way — a title's certification level reflects test evidence, not entitlement or payment state.
- The consumer runtime product should not depend on publisher revenue to remain viable.

Pricing, revenue recognition, taxes, and storefront commercial agreements require a separate commercial plan.

## 18. Dependencies and constraints

### 18.1 Technical dependencies

- Wine and its ARM64EC/WoW64 evolution;
- a production-quality x86/x64-to-ARM64 execution path;
- Metal and macOS feature availability;
- a viable D3D10/11 Metal provider;
- Metal12 reaching a commercially usable D3D12 feature subset on schedule, since GPTK/D3DMetal is not redistributable and no bootstrap provider substitutes for it (SPIKE-LEGAL-001, ADR-0012);
- storefront installer/authentication behavior;
- codec and redistributable licensing;
- physical Mac and Windows test capacity.

### 18.2 Organizational dependencies

- graphics compiler and driver-level expertise;
- Wine and Windows API expertise;
- macOS platform/security expertise;
- compatibility test automation;
- publisher and anti-cheat partnerships;
- legal review of redistribution, reverse engineering, codecs, trademarks, and storefront terms.

### 18.3 Product constraints

- Apple-silicon-only;
- modern baseline only: x64 guest games, D3D10/11/12/Vulkan renderers, rolling macOS support window, 16 GB certified memory floor (ADR-0011);
- no kernel driver execution;
- no hidden anti-cheat or DRM circumvention;
- no global mutable prefix as the support unit;
- no cloud requirement on the installed launch hot path;
- no unsupported configuration represented as Certified Mode.

## 19. Release gates

### 19.1 MVP gate

The MVP can be released to external developers/testers only when:

- all P0/MVP requirements have passing evidence or approved, visible exceptions;
- at least eight titles complete installation, first launch, second launch, gameplay scenario, clean exit, save write/read, and rollback tests;
- runtime lifecycle fault injection passes;
- no save-loss or host-root exposure defect remains open;
- all shipped components are signed, notarized where applicable, inventoried, and license-reviewed;
- diagnostic bundles pass privacy review;
- exact build and host selectors are enforced;
- support status does not overstate evidence;
- the team can reproduce a seeded customer failure from a bundle.

### 19.2 Beta gate

Private/public beta additionally requires:

- continuous update detection and impacted-test scheduling;
- canary health and automatic rollback;
- representative host classes across supported GPU and memory tiers;
- performance, long-session memory, audio, input, media, and accessibility gates;
- stable incident, revocation, and security response procedures;
- Custom Mode isolation;
- support playbooks and defined response ownership.

### 19.3 GA gate

GA additionally requires:

- owned Metal12 support for the declared D3D12 subset and launch catalog;
- production control-plane SLOs, cost controls, and auditability;
- mature release rings and independent component promotion;
- proven regression MTTR for top-catalog titles;
- publisher pilot capability;
- legal approval of distribution and third-party component strategy;
- no unresolved critical security or data-protection issue;
- a defensible roadmap for future macOS and Apple GPU generations.

## 20. Risks

The authoritative register with owners, triggers, and contingencies is [13_RISK_REGISTER.md](13_RISK_REGISTER.md); the list below is a summary of the highest product risks.

1. Metal12 takes longer than the commercial runway (R-003).
2. FEX/ARM64EC macOS integration has correctness or performance blockers (R-001).
3. Storefront, DRM, codec, or Apple-component redistribution terms limit the bootstrap path (R-010).
4. Apple platform changes invalidate undocumented assumptions (R-008).
5. Game updates arrive faster than the lab and profile process can certify (R-013).
6. Players evaluate catalog count rather than reliability (R-024).
7. Anti-cheat support remains partnership-limited (R-022).
8. Physical lab and diagnostics costs scale faster than revenue (R-027).
9. A compatibility runtime expands the attack surface through untrusted Windows code and JIT (R-018).
10. A mutable Custom Mode contaminates certified support unless isolation is uncompromising (R-021).

## 21. Open product questions

- Which 8–12 games form the MVP catalog, and what engine/API coverage is required?
- Which storefront gives the best first integration trade-off between user value and implementation risk?
- What support promise differentiates Playable from Certified for partially open-ended games?
- How long may a player continue using a stale certification after a game update?
- Should the client retain an older storefront build when technically and contractually possible?
- What is the commercial boundary between free experimental launch and paid certified support?
- Which modifications are compatible with a future competitive integrity mode?
- What telemetry is necessary to detect severe regressions without over-collecting?
- How are games with user-generated scripts/mods represented in the support state?
- What publisher evidence and contractual commitments are required before displaying Competitive Certified?
- What is the minimum acceptable D3D12 feature subset for GA?
- Which country/region privacy and consumer-protection obligations shape account, diagnostics, and subscription design?

These questions have owners and planned spikes in [16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md](16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md).

## 22. Approval

The PRD becomes an approved baseline when Product, Engineering, Security, Compatibility Operations, Design, and Legal agree on:

- MVP catalog and storefront;
- exact P0 requirements and exceptions;
- certification definitions;
- CPU execution-provider redistribution strategy; no bundled D3D12 bootstrap (ADR-0006, ADR-0012);
- privacy and telemetry defaults;
- release gates;
- indicative staffing and runway;
- the boundary between Certified, Custom, and unsupported use.

Changes that alter these commitments require a PRD revision, architecture impact review, and traceability update.
