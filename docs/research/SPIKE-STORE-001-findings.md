# SPIKE-STORE-001 — Findings: First Storefront Evaluation

**Version:** 0.2 (research complete)
**Status:** Research findings with proposed decision — catalog cross-check complete; pending founder approval
**Date:** 23 July 2026
**Author:** Tim Isaev
**Related:** [Open questions / SPIKE-STORE-001](../docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md) · [Legal findings](SPIKE-LEGAL-001-preliminary-findings.md) · [Publisher integration](../docs/17_PUBLISHER_AND_ANTI_CHEAT_INTEGRATION.md) · [ADR-0011](../adr/ADR-0011-modern-baseline-only.md)

> Compiled from primary sources fetched 23 July 2026 (storefront agreements, developer documentation) plus dated secondary reporting. Confidence per claim: **[P]** primary-fetched, **[S]** secondary/consistent press, **[U]** unverified this pass. ⚖️ marks items for the SPIKE-LEGAL-001 counsel checklist.
>
> **Superseded in part (24 July 2026) — read before implementing any `steamcmd` flow.** These findings are preserved as the research record of 23 July. The **shipped-product** posture has since narrowed: the [pre-counsel assessment](SPIKE-LEGAL-001-verdict.md) item 6 restricts Alloy to read-only local `appmanifest_*.acf` discovery and user-operated official-client actions, and **removes automated `steamcmd` orchestration from the v1 design** ([doc 18 §9](../docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md)). `steamcmd` use against our own entitled **lab** accounts is a separate question, still governed by doc 18 §8 (documented automated test-account use) and still exposed to the same SSA automation clause.

---

## 1. Question

Which storefront does Alloy integrate first? Candidates: Steam, GOG, Epic Games Store. Criteria per doc 16: install discovery, authentication handoff, update/build identity, offline behavior, multiple library locations, launcher process complexity, client x64-purity (ADR-0011), terms and partner posture, addressable candidate catalog — decided on user value, integration reliability, legal clarity, automation, support burden.

## 2. Key facts

### Steam

- **The Windows Steam client went native 64-bit on 19 December 2025** [S — consistent across many outlets]; the 32-bit branch (Windows 10 32-bit only) froze 1 January 2026. Client floor is Windows 10 x64. `steamwebhelper` (CEF UI) was already 64-bit multi-process; `steamservice.exe` bitness unconfirmed [U]. Net: the storefront-client x64-purity concern in doc 16 — written when `steam.exe` was 32-bit — is now largely resolved for Steam.
- **Build identity is the strongest of the three**: per-game `appmanifest_<appid>.acf` carries `buildid` (globally incrementing integer) plus installed-depot list; depot manifests enumerate files with SHA-1 hashes [P — steamdb.info/faq]. Since 2022, manifest downloads require an ownership-gated request code valid 15 minutes — build access always rides a real entitled account, which matches our lab-account model but rules out anonymous historical-build archiving.
- `libraryfolders.vdf` gives first-class multi-library discovery [S]. Offline mode has no Valve time limit (needs prior "remember login"; third-party DRM like Denuvo re-validates on its own schedule regardless) [S].
- `steamcmd` supports forced Windows-platform depot download and app validation; anonymous login is confirmed, credentialed owned-content flow is well-known but was not re-verified against a primary source this pass [U].
- **Steam Subscriber Agreement (current version 20 April 2026)** [P]: §4.C prohibits "any form of scripts, bots, macros, or other non-human-controlled systems ('Automation') to interact with Content and Services" ⚖️; §2.G prohibits reverse engineering and — separately — emulating Steam network protocols or hosting matchmaking without written permission ⚖️ (reinforces the standing architecture rule: always run the real Steam client, never emulate it); §4.D/§9.C allow account termination without notice or refund. Steam Web API terms [P]: per-app key, 100k calls/day, revocable at will.
- **No Valve statement or enforcement precedent for or against Wine-based Mac compatibility layers running the Windows Steam client** — CrossOver/Whisky have done so for years without documented bans. Tolerated practice, not policy [U — absence of evidence].
- Partner posture: standard Steamworks program; Steam Deck Verified recently extended to third-party SteamOS *hardware*, but no track exists for third-party compatibility-*software* vendors [S/U].

### GOG

- **DRM-free single-player is verified policy, and Galaxy is optional by design**: GOG's developer FAQ states single-player/offline functionality "should work regardless of whether the user is using GOG GALAXY or not," with SDK calls failing catchably when Galaxy is absent [P — docs.gog.com/faq]. One historical breach (Hitman 2016, Sept 2021) was pulled within a month after backlash [S].
- **Offline installers are generated server-side for every Master-branch publish** [P — docs.gog.com/offline-installers]. However, the official Galaxy SDK/API exposes **no build-ID, version, or update-detection endpoint at all** [P — docs.gog.com/galaxyapi, verified negative]: exact-build fingerprinting must come from installer filenames/metadata (embedded version strings; `build_id`/`version_name` fields observed in unofficial API captures) — a lab follow-up to standardize the method.
- For Alloy this is the best structural fit of the three: the installer *is* the artifact — content-addressable into our CAS directly, no client required inside the runtime for DRM-free titles, fully offline by design.
- No automation/third-party-downloader ban was located; community downloaders (gogdl, lgogdownloader, Heroic) have operated for years untouched [U — the consumer-facing Galaxy Licence Agreement, effective 9 Mar 2026, blocked automated fetch and remains unread ⚖️].
- Weaknesses: catalog ~12k titles [S — single source], modern AAA under-represented or delayed; the macOS Galaxy client is Intel-only (irrelevant to Alloy — we would run the Windows Galaxy client in-runtime, or skip Galaxy entirely for DRM-free installs).

### Epic Games Store

- Store EULA (effective 15 Jan 2025) [P]: bars reverse engineering (§2.e) and "unauthorized software programs to gain advantage" framed around cheating (§2.g). The separate account-level Epic Games ToS (effective 28 Nov 2025) [P] bars "bot software or services to automate your use of Licensed Products" (§4, gameplay-scoped) and reverse engineering (§3), and explicitly scopes the Store out to the EULA. **Across both documents, nothing names third-party store/library clients or download/launch automation** — a real textual difference from Steam SSA §4.C, not just absence of evidence. No enforcement precedent found against Legendary/Heroic in years of operation (upstream repo checked directly — no DMCA/C&D history) [U — absence of evidence].
- Build identity exists (chunked manifests with `BuildVersion`/`BuildId`) but is documented **only by community reverse engineering** — Epic publishes no manifest spec [S]. Integration would stand on an unofficial API surface.
- The Windows EGS client under Wine is the most fragile of the three: CrossOver added support only in v25 (2025) and shipped a download-breakage fix in v26 (Feb 2026) [S — CodeWeavers pages 403'd; secondary only]. Offline behavior and multi-library support were not verified [U].
- Commercially interesting posture (0% take on first $1M/yr, generally interoperability-friendly public stance), but no compatibility-vendor track found [S/U].

## 3. Decision matrix

Scores 1–5 against doc 16's five decision criteria (facts above; catalog row provisional until SPIKE-CATALOG-001 lands):

| Criterion | Steam | GOG | Epic |
| --- | --- | --- | --- |
| User value (where target users' libraries and wishlists live) | **5** | 2 | 3 |
| Integration reliability (client under Wine, moving parts) | **4** | **5** | 2 |
| Legal clarity (explicit terms vs. gaps, enforcement history) | 3 | **4** | 3 |
| Automation / build identity (lab + CAS fit) | **4** | **5** | 2 |
| Support burden (prior art, failure surface) | **4** | **4** | 2 |
| Addressable modern-AAA catalog (provisional) | **5** | 2 | 3 |
| **Total (unweighted)** | **25** | **22** | **15** |

Steam's two 5s are the ones a commercial product cannot substitute: the users and the catalog are there. GOG's 5s are engineering conveniences — valuable, but they don't move revenue. Epic trails on every axis that costs engineering time.

## 4. Proposed decision

1. **First storefront: Steam.** The Windows Steam client runs inside the Alloy runtime (CrossOver-precedent pattern); install discovery via `libraryfolders.vdf` + ACF parsing; build fingerprinting via `buildid` + depot manifests on entitled lab accounts; never emulate Steam protocols (SSA §2.G) — the real client is a hard runtime dependency for Steam titles.
2. **Second storefront: GOG**, at MVP+1 rather than post-beta — earlier than doc 11's generic "second storefront in Phase 3" if catalog overlap justifies it. Rationale: near-zero integration cost for DRM-free installer-based titles, the cleanest possible lab/CAS fingerprinting story, and dual-storefront differential testing for titles on both (a certification-lab asset, not just reach).
3. **Epic: deferred indefinitely.** Revisit only on partner interest or a catalog-exclusive must-have.
4. **Mitigations for the Steam ToS gray zone** ⚖️ (feeds the existing counsel checklist): lab automation runs only on dedicated entitled lab accounts; no multiplayer/stat/achievement automation ever; no protocol emulation; document the CrossOver-precedent reliance; seek a Valve conversation once traction exists.

## 5. Open items

| # | Item | Where it lands |
| --- | --- | --- |
| 1 | `steamservice.exe` bitness; credentialed `steamcmd` depot flow re-verification; Valve's own 64-bit-client patch notes (Dec 2025 claim rests on consistent press only) | Phase 0 storefront install/fingerprint proof (doc 11) |
| 2 | Standardize GOG installer-metadata → build fingerprint method (no official API exists — verified negative) | Lab fingerprinting follow-up in the same proof |
| 3 | GOG consumer legal texts (User Agreement; Galaxy Licence Agreement, 9 Mar 2026) — support.gog.com blocked all automated fetches; the one remaining unread primary ToS | ⚖️ counsel checklist addition |
| 4 | ~~Catalog cross-check~~ — **resolved** by SPIKE-CATALOG-001 §9.5: all 13 portfolio titles on Steam; 7 also on GOG (5 with DRM-free builds to certify directly) — supports GOG at MVP+1 | Closed |
