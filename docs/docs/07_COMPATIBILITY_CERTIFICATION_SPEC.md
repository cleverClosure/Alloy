# MGCR Compatibility Certification Specification

**Version:** 1.0  
**Status:** Proposed normative specification  
**Date:** 20 July 2026  
**Owner:** Compatibility Engineering  
**Related:** [PRD](02_PRD.md) · [Technical architecture](04_TECHNICAL_ARCHITECTURE.md) · [Test strategy](08_TEST_AND_QUALITY_STRATEGY.md) · [Profile specification](05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md)

---

## 1. Purpose

Certification is the product promise that an exact Windows game build has passed a defined test scope on specified Mac host classes through an exact runtime generation and profile. It is not a permanent property of a title name.

A certification record binds:

```text
game + storefront + branch + game build + launcher build
+ host capability matrix
+ runtime generation + profile revision
+ test plan and scenarios
+ outputs, tolerances, limitations, and date
```

## 2. Principles

1. **Exactness:** no certification without exact selectors.
2. **Scope transparency:** users see what was tested and what was not.
3. **Repeatability:** another authorized lab runner can recreate the test.
4. **Differential evidence:** Windows reference behavior is used where appropriate.
5. **Performance quality:** average FPS alone is insufficient.
6. **Long-session safety:** memory, save, input, audio, and lifecycle behavior are tested.
7. **Continuous validity:** relevant upstream changes trigger reevaluation.
8. **No protection circumvention:** anti-cheat and DRM limits are explicit.
9. **Conservative claims:** uncertainty lowers the level rather than being hidden.
10. **Independent rollback:** a failed candidate does not erase prior evidence or working runtime.

## 3. Certification levels

Certification levels are the evidence-bearing subset of the nine-value support-status model in PRD §14. Experimental (§3.3), Launches (§3.4), Playable (§3.5), Certified (§3.6), and Competitive Certified (§3.7) are levels: a lab awards them against the minimum-scope criteria below. Unsupported (§3.1) and Untested (§3.2) are included here for completeness — they describe the evidence boundary this taxonomy starts from — but, like Certification stale and Quarantined (see §14 below, Status downgrade policy), they are statuses the platform derives from the absence, expiry, or revocation of evidence rather than a passing test run. For this reason the `certification.level` enum in the game-profile schema ([`game-profile.schema.json`](../schemas/game-profile.schema.json)) is exactly these five values — `experimental`, `launches`, `playable`, `certified`, `competitive-certified` — and admits no value for Unsupported, Untested, Certification stale, or Quarantined.

### 3.1 Unsupported

Per PRD §14: a known hard blocker exists, or the title is outside product scope.

Examples:

- mandatory Windows kernel driver;
- protection vendor explicitly rejects the runtime;
- required graphics feature has no semantically correct implementation;
- game cannot be distributed or tested lawfully;
- architecture unsupported (such as a 32-bit x86 game executable; ADR-0011 excludes these from certification regardless of evidence).

Unsupported is evidence, not a moral judgment. The UI states the blocker class.

### 3.2 Untested

Per PRD §14: no valid evidence exists for the exact build/host. A community report or adjacent build does not change this state.

### 3.3 Experimental

Engineering has a known configuration and limited evidence, but one or more critical dimensions remain unstable, manual, or unmeasured.

Minimum evidence:

- exact build fingerprint;
- installation or launch attempt;
- assigned owner;
- known blocker/next test;
- no misleading Certified UI.

### 3.4 Launches

Minimum scope:

- clean installation or existing-install discovery;
- first launch reaches expected initial application/window;
- second launch;
- clean stop/exit behavior or documented failure;
- no save-loss or host security violation.

Gameplay is not claimed.

### 3.5 Playable

Minimum scope:

- all Launches requirements;
- a defined gameplay scenario reaches and sustains interactive play;
- input, audio, and required cutscene/media path pass for the scenario;
- save and load pass;
- limitations are documented;
- no severe repeatable platform crash in the scenario;
- minimum performance floor is defined (§8) and passed for tested host classes.

Playable may cover only a disclosed campaign section or mode.

### 3.6 Certified

Minimum scope:

- exact build and host matrix;
- installation/update and first/second launch;
- required launcher/authentication behavior;
- representative gameplay scenarios;
- save/load and rollback;
- controller and/or keyboard/mouse path;
- audio and media;
- display/presentation modes in scope;
- cold and warm cache;
- frame-time and shader-stutter gates;
- memory-pressure and endurance test;
- clean exit and abnormal-exit recovery;
- no unresolved critical security/privacy issue;
- current signed profile/runtime/evidence;
- disclosed limitations;
- canary health passes.

### 3.7 Competitive Certified

All Certified requirements plus:

- explicit publisher and anti-cheat/vendor authorization;
- approved runtime integrity measurement;
- no unapproved modifications;
- tested sign-in, matchmaking, session join, match completion, reconnect, and update behavior;
- voice/chat and network behavior as applicable;
- vendor rejection/error paths;
- signed scope identifying game mode, region, anti-cheat build, and runtime generation;
- incident/revocation contact path.

Competitive Certified cannot be inferred from ordinary multiplayer success.

## 4. Certification matrix

A matrix dimension is included when it can materially affect behavior.

### Required dimensions

- exact game build;
- exact launcher build or allowed range;
- storefront and branch;
- macOS major/minor and exact build (within the rolling current-plus-previous-major window; ADR-0011);
- Apple GPU capability family;
- unified-memory class (16 GB certified floor; ADR-0011);
- runtime generation;
- profile revision;
- provider versions;
- display mode needed by the test;
- input device class;
- network/offline mode where relevant.

### Conditional dimensions

- HDR versus SDR;
- 60/120/variable refresh;
- controller models/features;
- internal versus external display;
- microphone/voice;
- locale/IME;
- filesystem location and case behavior;
- 32-bit versus 64-bit helper process (helpers only, ADR-0011);
- low-storage or memory-pressure conditions;
- mod/integrity state;
- account region;
- ray tracing or advanced feature tier.

The matrix uses equivalence classes backed by evidence. It does not require every commercial Mac model when capability identity is genuinely equivalent.

## 5. Test-plan structure

A test plan is versioned and contains:

```yaml
id: tp_game_001_v17
gameId: game_001
preconditions:
  - clean runtime generation
  - owned test account
  - exact storefront branch
scenarios:
  - install
  - first_launch
  - second_launch
  - load_reference_save
  - gameplay_scene_a
  - gameplay_scene_b
  - controller_hotplug
  - audio_device_change
  - save_write_read
  - endurance_60m
  - abnormal_termination
  - rollback
metrics:
  frameTime: [p50, p95, p99, p999]
  memory: [peak, slope, pressureEvents]
  shader: [syncCompileCount, stallMs]
artifacts:
  - structured events
  - selected screenshots/reference images
  - traces
  - crash/hang bundles
passPolicy: ...
```

## 6. Scenario classes

### 6.1 Installation

- clean install;
- existing storefront install discovery;
- interrupted download;
- insufficient storage;
- dependency installation;
- storefront repair;
- runtime reinstall;
- uninstall preserving saves.

### 6.2 Launch

- first launch;
- second/warm launch;
- offline launch where supported;
- launcher sign-in;
- launcher update;
- no visible window;
- clean exit;
- forced stop;
- restart after crash.

### 6.3 Gameplay

Scenarios should exercise:

- representative rendering workload;
- menu/UI;
- camera movement and effects;
- checkpoint/save;
- scripted cutscene;
- streaming/level transition;
- controller and mouse/keyboard;
- networking where in scope;
- multiple graphics queues or feature paths where relevant.

### 6.4 Native services

- controller hot-plug and rumble;
- relative mouse capture and focus transitions;
- audio device change;
- microphone permission where relevant;
- media playback and seeking;
- fullscreen/windowed/display switch;
- HDR toggle where supported;
- locale/input method where relevant.

### 6.5 Reliability

- 30–120 minute endurance, title-dependent;
- memory-pressure injection;
- low disk space;
- daemon/client restart;
- candidate runtime failure;
- cache deletion/rebuild;
- save conflict;
- network interruption;
- storefront outage simulation where possible.

### 6.6 Security/integrity

- unsigned/tampered profile;
- modified runtime object;
- path traversal/symlink attempts;
- unrecognized child process;
- Custom Mode separation;
- revoked metadata;
- anti-cheat integrity state.

## 7. Windows reference oracle

The Windows reference is used to establish observable behavior, not to require identical implementation or identical performance.

Reference inputs may include:

- API feature queries and return values;
- shader/PSO creation;
- selected frame images;
- resource/queue events;
- process tree;
- window/input/audio events;
- save outputs;
- timing markers;
- crash behavior.

### 7.1 Comparison classes

| Class | Rule |
| --- | --- |
| Exact | Hash/byte equality required, such as save fixture or deterministic API result |
| Numeric tolerance | Values must fall within defined absolute/relative tolerance |
| Visual tolerance | Perceptual and region masks; no material artifact |
| Behavioral | State sequence and outcome must match |
| Performance | Mac-specific gate; Windows used as context, not direct equality |
| Informational | Captured for diagnosis, not pass/fail |

### 7.2 Limitations

A visual difference may be acceptable when it is:

- caused by known color-management differences;
- within approved antialiasing/noise tolerance;
- not visible in motion or material to gameplay;
- documented and stable.

Missing geometry, corrupt shadows, incorrect depth, flashing, persistent color error, broken UI, or temporal instability is normally material.

## 8. Performance gates

Every Certified scenario defines:

- target resolution and quality settings;
- display refresh and VSync/VRR state;
- warm/cold cache;
- session duration;
- power/thermal precondition;
- frame-time percentiles;
- stutter-event definition;
- shader/PSO synchronous stall limit;
- memory peak and growth-slope limit;
- CPU translation overhead indicators;
- GPU idle/synchronization indicators;
- input/audio quality where measurable.

These thresholds are set per title and host class; this document does not fix platform-wide numeric values. They instantiate the frame-pacing and shader-stutter framework defined in PRD §12 (NFR-PERF-002, NFR-PERF-003) — average FPS alone cannot satisfy a gate, and synchronous shader/PSO stalls must be bounded and measured cold and warm.

A title may be Certified at a specific preset rather than implying all settings work. The UI exposes the certified preset and host scope.

## 9. Evidence record

An evidence record contains:

- certification run ID;
- runner identity and attestation;
- test-plan digest;
- exact component and build digests;
- host capabilities;
- scenario results;
- metrics and thresholds;
- comparison artifacts;
- failures and waivers;
- known limitations;
- reviewer approvals;
- publisher/vendor scope where applicable;
- creation and expiration time;
- signature.

Large artifacts remain in controlled storage; the record binds to their digests.

## 10. Waivers

A waiver is exceptional and cannot hide a core product failure.

Allowed examples:

- non-material cosmetic variance;
- publisher-confirmed unavailable feature;
- one host class excluded from the profile;
- optional mode not part of advertised scope.

A waiver includes:

- issue and severity;
- affected scope;
- user-visible limitation;
- owner;
- rationale;
- compensating control;
- expiration/review;
- approvals.

No waiver may permit save loss, host compromise, false Competitive status, or a known severe crash in the advertised scenario.

## 11. Certification expiry and invalidation

Triggers include:

- game build change;
- launcher build change;
- anti-cheat/DRM update;
- profile or feature-mask change;
- runtime component change;
- macOS update;
- new Apple GPU capability family;
- evidence expiration;
- severe field regression;
- signing/security incident;
- publisher/vendor withdrawal.

### 11.1 Impact analysis

The control plane computes affected certifications from an evidence/dependency graph. A change may require:

- no retest because identity and semantics are unaffected;
- targeted scenario rerun;
- full host-matrix rerun;
- immediate quarantine/revocation.

The impact decision is itself audited.

## 12. Canary and field health

Before stable promotion:

- internal/lab ring passes;
- canary cohort receives the exact candidate;
- local candidate health window monitors launch, first frame, abnormal exit, device loss, severe memory pressure, and rollback;
- aggregate rates are compared with the previous generation;
- thresholds require minimum sample size and guard against noisy small cohorts.

Severe local failure can trigger per-title rollback even before cloud consensus.

## 13. Regression severity

| Severity | Definition | Response |
| --- | --- | --- |
| S0 Security/data loss | Host compromise, credential exposure, save deletion/corruption caused by platform | Revoke/quarantine immediately; incident response |
| S1 Unplayable | Install/launch blocker, frequent crash, anti-cheat rejection for advertised mode | Stop promotion; rollback/quarantine |
| S2 Major degradation | Severe stutter, rendering corruption, broken input/audio/media, long-session leak | Block certification or downgrade status |
| S3 Moderate | Workaround exists; limited mode/feature affected | Document, scope, prioritize |
| S4 Minor | Cosmetic/non-material issue | Track; may waive with evidence |

## 14. Status downgrade policy

- Certified → Playable when a non-core certified dimension fails but the advertised gameplay path remains safe.
- Certified → Certification stale when exact evidence no longer applies.
- Any level → Quarantined for severe security/correctness regression.
- Competitive Certified → Certified, with multiplayer marked unsupported in the disclosed limitations, when vendor scope lapses.
- Status changes are signed and visible with reason/date.

The product does not silently preserve a higher badge.

## 15. Manual versus automated testing

Automation is required for repeatability, but manual expert review remains necessary for:

- visual quality;
- subjective frame pacing/input feel;
- complex open-world progression;
- accessibility;
- account/launcher edge cases;
- anti-cheat/vendor behavior;
- newly observed failure classes.

Manual results use a structured checklist and evidence attachments.

## 16. Flaky tests

A flaky test:

- is labeled and assigned;
- cannot be hidden by repeated retries;
- has retry counts recorded;
- is excluded from gating only through a time-bounded waiver;
- is tracked by failure probability and environment;
- must be fixed or replaced before it masks severe regressions.

## 17. Certification publication

Public support metadata includes:

- level;
- exact or human-readable build;
- storefront/branch;
- tested date;
- Mac classes;
- key settings and scenarios;
- limitations;
- multiplayer/integrity scope;
- status-change reason.

It excludes proprietary traces, test accounts, private publisher builds, and sensitive security details.

## 18. Recertification service objectives

Initial planning objectives for top-catalog titles:

| Event | Objective |
| --- | --- |
| Update detected | Within 1 hour of storefront visibility where automation allows |
| Impacted plan scheduled | Within 2 hours |
| Smoke result | Within 6 hours |
| Safe rollback/profile mitigation | Within 24–48 hours for reproducible critical regressions |
| Full matrix result | Title-dependent, target within 72 hours |
| Public status update | As soon as evidence changes; do not wait for final fix |

These are operational targets, not promises until measured capacity is established.

## 19. Certification review roles

| Role | Responsibility |
| --- | --- |
| Compatibility engineer | Owns title profile and scenario |
| Subsystem engineer | Reviews fixes/workarounds in CPU, graphics, services, Wine |
| Lab operator/platform | Ensures runner integrity and test repeatability |
| Performance engineer | Reviews thresholds and regressions |
| Security | Reviews integrity, protection, grants, and sensitive changes |
| Product | Approves user-facing scope/limitations |
| Publisher partner | Reviews private findings and vendor scope where applicable |
| Release authority | Signs and promotes profile/evidence |

No single engineer should author, approve, and sign a stable high-risk profile alone.

## 20. Certification checklist

The evidence-scope checklist for Certified is defined in §3.6; a title cannot display Certified until every item there passes. Before the badge is displayed, release gating additionally requires:

- no S0/S1 issue remains (§13 regression severity);
- waivers are approved and time-bounded (§10);
- rollback generation is retained (§2 principle 10; §11);
- anti-cheat claims match explicit vendor scope, even when Competitive Certified (§3.7, §21) is not sought.

## 21. Competitive certification checklist

The requirements for Competitive Certified are defined in §3.7 (which includes all Certified requirements, §3.6); a title cannot display Competitive Certified until every item there passes. Before the badge is displayed, release gating additionally requires:

- ban-risk messaging is tested;
- incident/revocation contact path is verified active, not merely documented;
- no undocumented process injection or protection bypass exists.

## 22. Open certification decisions

- exact evidence-age expiration by title update cadence;
- minimum endurance duration by genre/engine;
- host equivalence rules across GPU generations;
- public benchmark disclosure level;
- acceptable provisional launch policy after game updates;
- save fixtures for games with cloud-only or encrypted saves;
- test-account governance for launchers and multiplayer;
- visual comparison tools and tolerances;
- criteria for certifying mod-capable titles;
- whether publisher acknowledgment is required for high-profile public certification.
