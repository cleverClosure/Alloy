# Alloy Legal, Open-Source, and Distribution Compliance Plan

**Version:** 1.0  
**Status:** Planning baseline; requires qualified legal review  
**Date:** 20 July 2026  
**Owners:** Legal, Open-Source Program Office, Release Engineering  
**Related:** [Architecture](04_TECHNICAL_ARCHITECTURE.md) · [Security](09_SECURITY_PRIVACY_THREAT_MODEL.md) · [Roadmap](11_ROADMAP_TEAM_AND_DELIVERY.md) · [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md)

---

## 1. Purpose and limitation

Alloy depends on open-source runtimes, platform SDKs, third-party launchers, game binaries, codecs, redistributables, dynamic translation, and interoperability work. Legal feasibility is therefore a release gate, not a final packaging task.

This document is an engineering/compliance planning framework. It is not legal advice and does not replace jurisdiction-specific counsel.

## 2. Compliance objectives

- preserve all open-source license rights and obligations;
- keep proprietary and copyleft boundaries intentional;
- distribute only components the company is authorized to distribute;
- obtain game, storefront, test-account, and publisher access lawfully;
- separate development-only tools from redistributable runtime components;
- document reverse-engineering/interoperability purpose and methods;
- respect DRM, anti-cheat, protected media, trademarks, and consumer law;
- provide notices, source offers, attribution, privacy disclosures, and export controls as required;
- retain auditable provenance for every shipped object.

## 3. Component compliance record

Every third-party component requires:

| Field | Description |
| --- | --- |
| Component/name/version | Exact source and revision |
| Upstream URL/repository | Canonical source |
| License(s) | SPDX identifiers plus exceptions |
| Linking/use model | Static, dynamic, IPC, tool-only, source-derived |
| Modified? | Patch set and owner |
| Distribution class | Bundled, downloaded, user-supplied, lab-only, service-only |
| Source obligation | Corresponding source, offer, scripts, notices |
| Patent/codec concern | Review result |
| Trademark/branding | Approved use |
| Export/security | Review where applicable |
| Vulnerability monitoring | Owner/feed |
| Replacement/contingency | Alternative if permission changes |
| Approval | Legal/OSPO/release record |

No stable runtime manifest may reference a component without this record.

## 4. Open-source strategy

### 4.1 Wine

- maintain license notices and corresponding source obligations;
- publish required modified source and build instructions where applicable;
- separate title profiles and proprietary services from Wine code;
- upstream generic changes when practical;
- track every downstream patch, license header, and provenance.

### 4.2 FEX and CPU translation dependencies

- confirm licenses of core, libraries, and any copied platform code;
- document macOS port contributions and proprietary boundary;
- preserve attribution and source obligations;
- review JIT/decoder dependencies separately;
- avoid copying incompatible code from other translators.

### 4.3 DXMT, MoltenVK, shader/compiler projects

- review exact license and transitive dependencies;
- understand whether modifications must be published and under what terms;
- separate runtime linking from build/tool use;
- review shader compiler IR libraries, validation code, and test corpora;
- retain source and build provenance;
- DXMT relicensed from MIT (≤ v0.80) to LGPL-2.1-or-later, and its tree now includes a D3D12 implementation (`src/d3d12/`); handle DXMT like Wine — dynamic-linking boundary, published fork source and diffs per release — and treat `src/d3d12/` as excluded material for the proprietary Metal12 clean room ([ADR-0012](../adr/ADR-0012-metal12-provenance-and-clean-room.md)). See [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md) §2.

### 4.4 Copyleft boundary

Architecture should prefer:

- explicit process/IPC boundaries where they match engineering design;
- clear shared-library obligations;
- no assumption that a separate process automatically resolves every license question;
- no proprietary code copied into a copyleft file without approval;
- no license “workarounds” that distort technical architecture.

Legal interpretation controls the final boundary.

## 5. Apple tools and SDKs

Classify each Apple component as:

- public redistributable system framework;
- development SDK/header;
- developer tool;
- evaluation/porting tool;
- redistributable runtime library;
- output artifact with its own terms;
- prohibited or restricted redistribution.

Questions include:

- May the component ship to end users?
- May generated shader/library output ship?
- Is use limited to porting native games?
- Are terms different for development, testing, and commercial redistribution?
- Can a third-party product expose the component as a general compatibility runtime?
- Are notices, OS minimums, or entitlements required?

Do not assume that technical availability implies redistribution permission.

Preliminary classification recorded for the two Apple components currently in scope: GPTK/D3DMetal is an evaluation/porting tool whose EULA limits distribution of the Apple Software to non-commercial purposes — a commercial product cannot bundle it, and the only known field pattern (a user fetching GPTK under their own Apple ID) is tolerated, not Apple-blessed. Metal Shader Converter *output* (`.metallib`) is marketed as shippable with a game; the converter tool's own EULA text is unverified. See [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md) §2, §5, §7.

## 6. Microsoft components and Windows redistributables

For each dependency such as Visual C++ runtime, .NET, DirectX helper, Media Foundation component, or web runtime:

- identify the official redistribution license;
- determine whether it can be bundled, downloaded from Microsoft, installed by storefront, or must be supplied by the user;
- retain original installer/signature and version;
- do not repackage unless authorized;
- record silent-install rights and user terms;
- test unsupported/expired installer behavior;
- distinguish open reimplementations from Microsoft binaries.

**Visual Studio Community eligibility (pre-counsel assessment, [verdict](../research/SPIKE-LEGAL-001-verdict.md) item 7).** An individual may use VS Community to build free or paid applications; a non-enterprise organization may have up to **five** Community users. "Enterprise" means **more than 250 PCs *or* more than US$1M annual revenue** — not "250 seats". Eligibility ends at a **sixth** Community user, **>250 PCs**, or **>US$1M** annual revenue; re-check at fundraising, acquisition, substantial growth, and annually. Redistribute only unmodified files on Microsoft's applicable Distributable List — debug and non-redistributable files are outside it — and preserve the licence and Distributable List for the exact toolchain release used.

## 7. Codecs and media patents

Media support may implicate:

- codec patent pools;
- platform-only decode rights;
- distribution royalties;
- protected-content systems;
- geographic variation.

The approved design may:

- use macOS system decode APIs without bundling a codec;
- require the game/storefront to provide licensed content;
- support only unprotected formats;
- omit a codec in some regions;
- negotiate publisher coverage.

Profiles must not silently download unapproved codec packs.

**Release gate (pre-counsel assessment, [verdict](../research/SPIKE-LEGAL-001-verdict.md) item 5 — escalated from "expected clean").** Routing decode through VideoToolbox/AudioToolbox is a strong factual argument, **not** a discharge of codec-patent obligations: the macOS licence itself notes that Apple's supplied AVC functionality is licensed for personal and non-commercial consumer use and that other uses may require a separate patent licence. Before any external binary:

- SBOM and binary scan proving the runtime contains no FFmpeg/libav codec implementation, no fallback decoder, and no GStreamer plug-in implementing a relevant patented codec;
- proof that VideoToolbox failure does not silently fall back to a bundled software decoder;
- a written architectural question to each relevant licensing administrator (Via LA for AVC/H.264, Access Advance for HEVC), with replies preserved in the release record;
- until a sufficiently clear written answer arrives, **H.264/HEVC and other unconfirmed patented-codec paths are disabled in external builds**, or item 5 is held as a release blocker.

A EULA disclaimer does not grant patent rights.

## 8. Game binaries and test data

### Consumer product

- user must own or be authorized to use the game;
- Alloy does not redistribute game assets unless contracted;
- runtime fingerprinting and compatibility behavior must be covered by terms and applicable interoperability law;
- do not bypass ownership checks.

### Lab

- acquire copies through approved accounts or publisher provision;
- document automated test-account use;
- respect concurrent/session limits;
- do not share private builds across tenants;
- store captures/saves under defined retention;
- publish no copyrighted game imagery beyond approved fair/contractual use.

## 9. Storefront integration

For each storefront:

- review client and developer terms;
- determine permitted automation and account handling;
- avoid scraping or credential interception where unsupported;
- prefer official protocol/launcher handoff;
- do not imply storefront endorsement;
- use approved trademarks/badges;
- handle regional availability and refunds accurately;
- keep ownership and purchases with the storefront unless a reseller agreement exists.

**Steam, v1 posture (pre-counsel assessment, [verdict](../research/SPIKE-LEGAL-001-verdict.md) item 6).** The SSA's automation provision prohibits scripts, bots and other non-human-controlled systems from interacting with Steam Content and Services; published SteamCMD documentation is not authorisation for a consumer product to automate a user's account. Absence of credential interception does not resolve it. **Permitted:** read local unencrypted `appmanifest_*.acf` without modification; detect installed game paths; let the user launch the official client; let login, install, update and account actions happen in Steam's own UI; launch an already-installed local executable after a user action. **Not shipped without Valve's written permission:** automatic login; storing or relaying credentials; driving the client by simulated input or process control; background SteamCMD to install/update/manage consumer games; automating purchases, accounts, reviews, achievements, playtime, trading or rewards; interfering with DRM or anti-cheat. **Automated SteamCMD orchestration is removed from the v1 design.**

## 10. Reverse engineering and interoperability

Engineering should document:

- interoperability objective;
- independently created implementation;
- sources consulted;
- clean-room boundaries where needed;
- no use of leaked/confidential code;
- no circumvention of access controls beyond legally approved interoperability activity;
- no protection bypass objective;
- jurisdiction and counsel guidance.

High-risk work, including shader bytecode, DRM, anti-cheat, and proprietary protocols, requires pre-approved research rules.

## 11. DRM and anti-cheat

- do not remove, disable, or misrepresent protection without publisher/vendor authorization;
- no kernel-driver emulation presented as supported;
- a game running with anti-cheat disabled must not be described as full multiplayer compatibility;
- vendor enablement agreements define measurement, privacy, support, and liability;
- security research follows responsible disclosure and legal approval;
- preserve logs/evidence of approved behavior without collecting secrets.

## 12. Trademarks and marketing claims

Review:

- product name and domain;
- use of Windows, DirectX, Metal, macOS, Steam, Epic, publisher, and game names;
- compatibility nominative use;
- screenshots/artwork;
- “certified,” “native,” “official,” “supported,” and performance claims;
- anti-cheat/vendor badges;
- comparative advertising.

Marketing must match exact evidence and cannot imply Apple, Microsoft, storefront, or publisher endorsement without permission.

## 13. Consumer protection and subscriptions

Commercial policy must address:

- clear supported catalog and exact limitations;
- changes after game/macOS updates;
- refunds/cancellation;
- automatic renewal;
- trial terms;
- offline use and entitlement expiry;
- discontinued title support;
- data deletion;
- regional warranties;
- age/minor accounts;
- accessibility representations;
- export/sanctions.

Do not sell “all Windows games” when the product certifies a curated catalog.

## 14. Privacy and data protection

Legal/Privacy reviews:

- account identifiers;
- pseudonymous telemetry;
- IP/network metadata;
- diagnostic bundles;
- publisher private data;
- test accounts;
- regional transfer;
- retention/deletion;
- data subject requests;
- subprocessors;
- incident notification;
- child/minor risk.

Data maps must match the technical event schema and actual implementation.

## 15. Export controls and sanctions

Review whether shipped cryptography, JIT/runtime technology, developer tooling, and services require:

- classification;
- filings/notifications;
- geographic restrictions;
- sanctions screening;
- publisher/private build access controls.

The release pipeline enforces approved distribution regions when required.

## 16. Notices and source compliance package

Stable distribution should generate:

- third-party notices;
- license text;
- copyright attribution;
- corresponding source/source offer where required;
- modified-source repository/tag;
- build scripts/instructions where required;
- SBOM;
- component provenance;
- privacy and terms;
- trademark acknowledgments.

The package is generated from component metadata, reviewed, and archived with each release.

## 17. Dependency intake gate

Before code enters a production branch:

1. identify exact source/license;
2. scan transitive dependencies;
3. legal/OSPO classification;
4. security review;
5. architecture boundary;
6. source/notice obligations;
7. redistribution approval;
8. provenance/build integration;
9. replacement risk;
10. owner.

A Git dependency or copied snippet is still an intake.

## 18. Release compliance gate

Before stable promotion:

- all runtime manifest components approved;
- no unknown license;
- notices/source obligations generated;
- private/dev-only Apple or publisher artifact absent;
- Microsoft/codec redistributables approved;
- game/storefront terms reviewed;
- signing/notarization complete;
- SBOM and vulnerability review complete;
- marketing claims match certification;
- regional privacy/consumer/export approvals complete;
- archive includes source/provenance/approvals.

Added by the pre-counsel assessment ([verdict](../research/SPIKE-LEGAL-001-verdict.md)); each is a hard gate on the first external binary:

- **LGPL modified-runtime path proven on a clean Mac** — CI builds the published corresponding-source package, substitutes a deliberately modified LGPL library, signs the resulting runtime as documented, and verifies it launches (item 4);
- **corresponding source, notices and EULA carve-outs published** for every LGPL component, with the elected LGPL version recorded per "2.1-or-later" component, and GStreamer audited **per plug-in** (item 4);
- **SBOM complete and codec-clean** — no bundled codec implementation or fallback decoder; patented-codec paths disabled unless written administrator coverage is on file (item 5);
- **FEX and MoltenVK obligations discharged** — both ship but were outside the original item-4 scope (item 4);
- **product renamed** and no external distribution under a mark that has not cleared (item 9);
- **Apple, Microsoft and third-party licence versions archived** for the exact build, including the Metal Shader Converter package licence (items 1, 2, 7).

## 19. Open compliance questions

- ~~exact Apple Game Porting Toolkit redistribution/use boundary~~ — **closed, not a legal question we still price**: GPTK/D3DMetal ships in no form and stays in the evaluation lab ([verdict](../research/SPIKE-LEGAL-001-verdict.md) item 3). Reopens only if Apple publishes terms expressly authorising a commercial third-party user-fetch flow;
- shader conversion output rights (preliminary answer: see [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md));
- FEX macOS port distribution obligations (preliminary answer: see [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md));
- DXMT integration/linking model (preliminary answer: see [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md));
- codec/patent coverage — **escalated to a release gate** ([verdict](../research/SPIKE-LEGAL-001-verdict.md) item 5): system-decoder-only is a good argument, not a discharge; needs written administrator coverage or the affected paths disabled (§7). Still a ⚖️ counsel item;
- Microsoft redistributable packaging (preliminary answer: see [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md));
- storefront automation and private branch use — **v1 posture decided** ([verdict](../research/SPIKE-LEGAL-001-verdict.md) item 6): read-only local discovery plus user-operated official-client actions; automated SteamCMD orchestration removed (§9). Steam SSA §4.C remains a ⚖️ counsel item for anything beyond that;
- game fingerprinting and interoperability analysis by jurisdiction (preliminary answer: see [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md));
- anti-cheat measurement contracts (preliminary answer: see [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md) — no macOS/Wine vendor opt-in program exists today);
- public use of game images/benchmarks;
- subscription support-change/refund policy (preliminary answer: see [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md));
- privacy regions and subprocessors;
- export classification;
- **trademark clearance for the product name** — the pre-counsel assessment reads the current name as a conflict and recommends renaming before the first external binary ([verdict](../research/SPIKE-LEGAL-001-verdict.md) item 9); ⚖️ counsel item, tracked as founder work.

**Explicitly outside the nine-item review.** The assessment clears none of: privacy and data protection, consumer terms and refunds, export controls and sanctions, game-publisher agreements, anti-cheat restrictions, tax, accessibility, security representations, or any non-U.S. law. Several already appear above and in §20; none are addressed by the nine items.

## 20. Required legal deliverables before external MVP

Sequenced per the pre-counsel assessment ([verdict](../research/SPIKE-LEGAL-001-verdict.md), "Recommended release sequence"): rename the product and repository; permanently remove GPTK user-fetch from the release configuration; limit Steam support to read-only local discovery and user-operated client actions; produce the full SBOM and remove unapproved codec implementations and GStreamer plug-ins; build and test the LGPL modified-runtime path on a clean Mac; publish the corresponding-source bundle, notices and EULA carve-outs; obtain written codec guidance or ship the first beta with the affected media paths disabled; archive the Apple, Microsoft and third-party licence versions for the build; and continue the Metal12 protocol indefinitely — item 8 never becomes "finished". Only after those controls is a limited external beta a reasonable risk decision, **and then only on these nine questions**.

- written component distribution matrix;
- open-source policy and notice/source pipeline;
- Apple tool/runtime memo;
- Microsoft/codec dependency memo;
- first-storefront terms review;
- game testing/fingerprinting/interoperability memo;
- DRM/anti-cheat research policy;
- privacy data map and notices;
- consumer terms/subscription outline;
- trademark/marketing review;
- publisher NDA/DPA/build-submission templates.
