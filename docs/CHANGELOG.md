# Documentation Changelog

## 1.7 — 25 July 2026

Completes counsel item 6. The 1.6 sweep was incomplete: four further places described prohibited Steam interaction, and the gate 1.6 shipped was exempting the most direct one.

- `research/SPIKE-LEGAL-001-preliminary-findings.md` gains the **supersession banner** it never received, naming the four positions the assessment overturned (GPTK user-fetch, codecs, the Visual Studio threshold, the trademark call). Its §2 matrix row said **"steamcmd fine"** — a flat statement written the day before the assessment said the opposite, in a document an engineer would implement from. Struck and replaced: §4.C automation is the operative prohibition rather than a residual gray, automated `steamcmd` is out of the v1 design, and no Steam credential or token is stored or relayed;
- doc 04 §18.1: the storefront adapter contract listed "**Authenticate** or hand off to official client" as co-equal options and permitted adapters to use "**command-line contracts**" and last-resort screen scraping. The contract is now handoff-only for sign-in and account actions; command-line contracts are available only where a storefront's own terms authorise them, and running `steamcmd` from an adapter is named as prohibited; screen scraping is never applied to a storefront client;
- doc 04 §18.6: token storage is scoped to storefronts publishing an official integration whose terms authorise it, with an explicit Steam carve-out — no credential, token or session artefact is stored or relayed, and sign-in happens solely in Steam's own UI;
- ADR-0011 §6 cited "the no-UI-automation rule in the architecture", which does not exist as stated — doc 04 §18.3 has a lab carve-out. Replaced with what the architecture actually says, including why the storefront-client exclusion is stated separately;
- doc 06 §6.2: `StartInstall`/`RepairInstallation` scoped to Alloy's own runtime generations and install records; Alloy does not invoke a storefront's verify-or-repair function on the user's behalf;
- the gate gains **check 6**. Check 5 exempts a document by path, so the allowlisted preliminary findings passed while saying `steamcmd fine`. Check 6 requires a research *findings* document naming `steamcmd` to carry a `Superseded` banner. Two earlier designs were rejected and the reasons recorded: a whole-file keyword search passed the real defect (because "prohibited" appears in an unrelated GPTK row), and a same-line rule failed the verdict for quoting the prohibition accurately. Validated against the actual pre-fix file, not only a fixture. Recorded in `spikes/STORE-001/results/2026-07-25-04-steam-readonly-second-sweep.md`.

## 1.6 — 25 July 2026

Counsel item 6 (Steam automation) is applied to the v1 design, and doc 18 §9 is enforced by a CI gate rather than asserted. What the product *runs* against Steam was already inside the permitted posture; what the documents *specified* was not.

- doc 19 **EPIC-013 restated**. The first-storefront epic committed us to "ownership, install, update, repair, authentication ... for one storefront", with stories for `installation`, `launcher update` and `verify/repair`, and accepted itself on "no credential interception" — the exact argument the pre-counsel assessment names and rejects, because SSA §4.C is a separate prohibition that the absence of credential interception does not answer. It also contradicted INS-008, the requirement it cited. Outcome, stories and acceptance are now read-only discovery, build identity, update *detection*, and user-initiated handoff to the official client;
- doc 04: `RuntimeDaemon` no longer "coordinates storefront installation and updates" — it sequences runtime work around storefront-performed installs and observes them through local manifests (§7); the UI-automation carve-out no longer reads as blanket permission — simulated input against a **storefront client** is prohibited in the product, and is not thereby cleared for the lab; the lab case is routed to the open SSA §4.C question in doc 18 §8 rather than decided here (§18.3);
- doc 11: the storefront workstream owns discovery, handoff and build-identity adapters rather than "install/auth/update adapters" (§3);
- doc 07: the recertification update-detection objective names the permitted detection route instead of hedging with "where automation allows" (§18);
- doc 14: **D-019 marked scope-narrowed (25 July 2026)** — the Steam decision record now carries the item 6 limits itself rather than leaving them only in doc 18; doc 16's SPIKE-STORE-001 closure records that `steamcmd` against entitled lab accounts stays an open §4.C question under doc 18 §8 rather than a completed mitigation;
- `research/SPIKE-STORE-001-findings.md` §5: the credentialed `steamcmd` depot-flow re-verification open item is **withdrawn** — it scheduled verification of a flow the design no longer contains;
- doc 18 §9 gains an **evidence** paragraph. `spikes/STORE-001/steam-readonly/steam-automation-gate.sh` runs on every CI build: it proves discovery is read-only by running the shipped discovery tool over a synthetic two-folder Steam library and failing if any byte, size, mode or mtime moved, and it fails if shipped code acquires a SteamCMD invocation, a credential or session surface, or a means of driving the client. Its companion `gate-selftest.sh` plants each prohibited flow in a synthetic repository, so the gate is known to reject what it claims to reject rather than merely known to be green. Recorded in `spikes/STORE-001/results/2026-07-25-03-steam-readonly-conformance.md`.

## 1.5 — 24 July 2026

SPIKE-LEGAL-001: a pre-counsel risk assessment against the nine-item counsel brief is recorded, and its corrections are propagated into the binding engineering constraints. **It is not counsel's answer — deliverable D10 stays incomplete and issue #13 stays open.**

- added `research/SPIKE-LEGAL-001-verdict.md`: the assessment recorded verbatim, with its own stated limits (no attorney-client relationship, no privilege, reviewer did not read the ADR, provenance log, source tree, SBOM, package EULAs or binaries; assumes Developer ID distribution);
- counsel brief revised to 0.2 — per-item **Pre-counsel verdict** lines; item 5 (codec decode) moved Tier C → **B** because the macOS licence's own AVC notice means system-decoder-only is a good argument, not a discharge; item 3 (GPTK user-fetch) moved to **Closed — do not ship**, removing the ambiguity rather than paying to justify it; item 7's eligibility threshold corrected (">250 seats" was wrong: it is **>250 PCs or >US$1M revenue**, with a five-user Community limit); item 9 escalated from "commission a search" to **rename before launch**; §6 constraints extended with the Steam, codec, GPTK and AI-provenance rules;
- doc 18: VS Community thresholds corrected (§6); codec release gate added — SBOM/binary scan, no silent fallback decoder, written administrator coverage or disabled patented-codec paths (§7); Steam narrowed to read-only local discovery plus user-operated client actions, automated SteamCMD orchestration removed from v1 (§9); release-compliance gate extended with the LGPL modified-runtime CI test, per-plug-in GStreamer audit, FEX/MoltenVK obligations, rename and licence archival (§18); open questions and deliverables re-sequenced, and the assessment's explicit non-coverage recorded (§19–§20);
- ADR-0012: evidence-hardening clauses 7–13 added — the protocol is **evidence, not a safe harbour**: hashed/timestamped input lists, externally timestamped provenance log, per-feature spec→design→implementation→test chain, recorded AI-tool use, verified-clean AI indexes, exposure-free similarity testing, contributor certification, candid exposure history;
- risk register R-010 and R-036 updated; doc 16 SPIKE-LEGAL-001 status updated; `research/SPIKE-STORE-001-findings.md` carries a supersession note so its `steamcmd` material is not implemented as written;
- decision log: **D-021 "Product name: Alloy" marked at risk** — its revisit trigger has fired; the old fallback shortlist is recorded as unscreened. A pre-existing defect is now flagged in the log: **the identifier D-021 is used twice**, and resolving it requires touching a signed audit block or a historical changelog entry, so it is a founder call;
- added `tools/gen-doc-manifests.py`; manifests regenerated with it rather than by hand. It reproduces every unchanged 1.4 entry byte-identically, and regenerating surfaced that **the 1.4 manifests were already stale by two files** — `research/SPIKE-LEGAL-001-counsel-brief.md` was never listed, and `research/SPIKE-CATALOG-001-findings.md` changed in the repo-wide lint pass after 1.4 was generated. Both are correct as of 1.5; `--check` now makes that drift detectable.

## 1.4 — 23 July 2026

Product naming: **Alloy** adopted as the product name (decision D-021), replacing the working name "MGCR" package-wide.

- all documents, schemas (`$id` URIs), examples, spike plans, and repository files renamed; the placeholder client name "GameHub.app" becomes "Alloy.app";
- historical anchor retained in the document map, glossary, and provenance log ("early drafts used the working name MGCR");
- counsel checklist item 9 concretized: trademark screen/registration for "Alloy" (Nice classes 9/41/42, adjacent-software knock-out check), clearance before public use; defensive domain acquisition noted;
- manifests regenerated under the new package name.

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
