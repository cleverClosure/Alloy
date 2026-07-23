# SPIKE-LEGAL-001 — Preliminary Findings: Redistribution and Interoperability Matrix

**Version:** 0.1 (research draft)
**Status:** Research findings — requires qualified counsel review before any external binary ships
**Date:** 23 July 2026
**Author:** Tim Isaev
**Related:** [Legal plan](../docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md) · [Open questions / SPIKE-LEGAL-001](../docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md) · [ADR-0006](../adr/ADR-0006-owned-d3d12-metal-and-reused-d3d11.md) · [Risk register R-010](../docs/13_RISK_REGISTER.md)

> **This is not legal advice.** It is an engineering-grade pre-counsel review compiled from primary sources (repository LICENSE files, vendor license pages, statutes, and official statements) as of 23 July 2026. Items marked ⚖️ require counsel sign-off before the first external release.

---

## 1. Executive summary

1. **No fatal blocker exists for the full-scope architecture.** Every component in the planned stack has a lawful development and distribution path, and the overall shape of doc 18's compliance plan survives contact with the actual license texts.
2. **The bootstrap D3D12 path is the weakest link.** Apple's GPTK EULA limits distribution of the Apple Software (including D3DMetal) to *non-commercial purposes* and scopes use to developing/testing/evaluating games. A commercial product cannot bundle D3DMetal. The only existing pattern is the Whisky/Mythic model — the end user downloads GPTK from Apple under their own Apple ID — which is tolerated practice, never Apple-blessed, and clashes with MGCR's one-click + signed-immutable-runtime thesis. This strengthens the PRD's D3D11-first MVP and raises the strategic value of Metal12.
3. **DXMT relicensed from MIT to LGPL-2.1-or-later after v0.80**, and its tree already contains a working LGPL'd D3D12-on-Metal implementation (`src/d3d12/`). Consequences: (a) DXMT must be handled like Wine — dynamically linked, source + diffs published per release; (b) DXMT's D3D12 code joins vkd3d/vkd3d-proton on the clean-room exclusion list for a proprietary Metal12.
4. **The clean-room requirement is structurally hard for a solo founder.** A one-person company cannot staff a two-team clean room. Decision required now (§6), because it constrains what the founder may read starting today.
5. **The Rosetta clock has a date.** Full Rosetta 2 ships through macOS 27 (~September 2026 release); macOS 28 (2027) retains only a subset for "older, unmaintained games." CrossOver publicly depends on Rosetta today and is racing to native ARM64. The production CPU path (FEX/ARM64EC) must be usable roughly when macOS 28 adopters appear (~fall 2027), or supported hosts must be pinned to macOS ≤ 27.

## 2. Distribution matrix

Distribution classes per doc 18 §3: **BUNDLE** (ship in product), **OFFICIAL-DOWNLOAD** (fetch vendor installer at install time), **USER-SUPPLIED**, **REIMPLEMENT** (use OSS reimplementation), **LAB-ONLY**, **AVOID**.

| Component | License / terms (verified) | Class | Key obligation / note |
| --- | --- | --- | --- |
| Wine (thin fork) | LGPL-2.1-or-later | BUNDLE | Publish fork source + diffs per release (CrossOver model); dynamic boundary to proprietary code |
| FEX-Emu incl. ARM64EC backend | MIT (deps all permissive) | BUNDLE | Notice retention only; macOS port may remain private; SBOM scan at fork commit |
| DXMT (current) | **LGPL-2.1-or-later** (≤ v0.80 was MIT) | BUNDLE | Same LGPL handling as Wine; publish source; do not silently freeze on the MIT snapshot without an explicit decision |
| MoltenVK | Apache-2.0 | BUNDLE | Notices; includes patent grant |
| vkd3d / vkd3d-proton | LGPL-2.1-or-later | AVOID (do not bundle) | **Clean-room exclusion list** for Metal12; reference-reading is contamination risk |
| DXC (DirectXShaderCompiler) | NCSA/LLVM-style permissive | BUNDLE | May embed/link to consume DXIL; the `dxil.dll` validator binary is under separate MS terms — not needed at runtime |
| DirectX-Headers / DirectX-Specs | MIT / CC-BY-4.0 | Use freely | Attribution; Microsoft publishes these for third-party implementation — strong footing for Metal12 |
| GStreamer core + base + good | LGPL | BUNDLE | Dynamic linking (project's own blessed model); **exclude** `ugly`/`bad` plugin sets |
| GPTK / D3DMetal | Apple EULA: use for developing/testing/evaluating games; distribution **non-commercial only** | USER-SUPPLIED at most; LAB-ONLY internally | Cannot ship in a commercial product; Whisky-pattern user fetch is tolerated, not blessed ⚖️ |
| Metal Shader Converter output (.metallib) | Apple markets "ship with your game" | BUNDLE (output) | Tool's own EULA text unverified ⚖️ |
| Rosetta 2 | macOS system component | Use (bootstrap/reference only) | Full through macOS 27; games-subset in 28; never a production dependency (per ADR-0005) |
| JIT entitlements (`allow-jit`, MAP_JIT) | Standard Hardened Runtime entitlement | Use | Compatible with notarized Developer ID; CrossOver precedent; per-thread W^X stable |
| VC++ redistributable | VS "Distributable Code" terms | OFFICIAL-DOWNLOAD | Fetch `aka.ms/vs/17/release/vc_redist.x64.exe` live, silent-install (winetricks convention) |
| Modern .NET (5+) | MIT / .NET Library License | BUNDLE | Explicit grant |
| Legacy .NET Framework | Proprietary MS EULA | REIMPLEMENT (Wine Mono) + OFFICIAL-DOWNLOAD fallback | Wine Mono is MIT/LGPL and now WineHQ-stewarded |
| DirectX End-User Runtime (d3dx9, xinput1_3, XACT, XAudio 2.7) | DirectX SDK EULA distributable-code clause | OFFICIAL-DOWNLOAD | Run `dxsetup.exe /silent`; **never** hand-extract loose DLLs |
| XAudio2Redist (2.9) | MS redistributable (explicit grant) | BUNDLE | Cleanest MS component; app-local |
| d3dcompiler_47.dll | Windows SDK redist list | BUNDLE | Free SDK license gate; app-local, sourced from SDK Redist folder |
| Media Foundation / any Windows system DLL | Windows EULA (not on any redist list) | AVOID / REIMPLEMENT | winegstreamer + VideoToolbox; USER-SUPPLIED escape hatch only, user's own Windows license |
| Software codecs (H.264/HEVC/VC-1/AAC decoders) | Patent pools (Via LA, Access Advance) | AVOID bundling | Decode via VideoToolbox/AudioToolbox only; HEVC is dual-pool and active; 2026 content-royalty push unsettled ⚖️ |
| corefonts (Arial et al.) | Terminated MS program | AVOID | Bundle Liberation Fonts (SIL OFL 1.1) instead |
| Steam integration | SSA + Steamworks terms | Integrate | Launch official client; read local `appmanifest_*.acf`; steamcmd fine; §4.C "Automation" text is the residual gray ⚖️ |
| Epic integration | EGS EULA | Integrate | Legendary/Heroic precedent (full protocol reimplementation, unenforced); no confirmed Sweeney endorsement — do not cite one |
| GOG integration | DRM-free by design | Integrate | Friendliest storefront; do not scrape the website |
| EAC / BattlEye / Denuvo | Vendor programs | Partner-enabled only | Linux/Proton opt-in programs exist; **no macOS/Wine equivalent**; CrossOver 26's anti-cheat wins are CodeWeavers engineering, not vendor sanction — never market as "officially supported" |

## 3. Interoperability law baseline

- **DMCA §1201(f)** permits circumvention solely for interoperability analysis of lawfully obtained programs — but MGCR's design (read unencrypted local metadata, launch official clients, never strip protections) mostly stays **outside §1201 entirely** because no technological protection measure is circumvented.
- **EU Software Directive 2009/24/EC Art. 5(3)** grants lawful users the right to observe/study/test program behavior (black-box observation — MGCR's main mode); **Art. 6** permits decompilation only when indispensable for interoperability, and contract clauses overriding it are void.
- **Sega v. Accolade (1992)** and **Sony v. Connectix (2000)**: intermediate copying during reverse engineering for interoperability is fair use — the doctrinal backbone if §1201 were ever reached.
- Doc 18 §10's clean-room/documentation requirements are the right controls; add the exclusion list from §6 below.

## 4. Marketing, subscription, and trademark constraints

- **FTC substantiation:** "Certified" claims require documented, repeatable test evidence proportional to the claim. MGCR's evidence-graph design *is* the substantiation — a genuine synergy. Until the lab exists, avoid the word "certified" in public copy; use "tested against [exact list]."
- **Subscriptions:** the FTC click-to-cancel (Negative Option) Rule was vacated in full by the 8th Circuit (July 2025); as of July 2026 there is no binding federal rule (new ANPRM in March 2026). **California's Automatic Renewal Law (amended effective July 2025) is the operative design constraint**: cancel in the same medium as signup, prominent online cancel path with no forced retention flow, express-affirmative-consent records retained. Design the billing flow to CA ARL; FTC §5 dark-pattern enforcement remains active.
- **Apple trademarks:** "Mac"/"macOS"/"Metal" only as referential phrases ("for Mac", "built with Metal"), less prominent than the product name; never in the product name as leading element; no Apple logo without written license. Attribution footer required.
- **Steam branding:** plain-text nominative use ("works with your Steam library") + non-affiliation disclaimer; no Steam logo without Valve approval.
- Windows/DirectX marks: nominative references to compatibility are standard practice; avoid "Windows" in the product name.

## 5. Impact on existing documents

| Document | Required change |
| --- | --- |
| ADR-0006 | Add consequence: bootstrap D3D12 via GPTK cannot ship commercially; bootstrap = lab/reference only, or user-supplied flow with explicit UX/integrity cost. Strengthens D3D11-first MVP. |
| 18_LEGAL §5 | Fill in GPTK classification: "evaluation/porting tool; runtime redistribution prohibited for commercial products; converter output shippable." |
| 18_LEGAL §4.3 | Record DXMT relicense (MIT ≤ v0.80 → LGPL-2.1+) and the LGPL compliance pipeline it now requires. |
| 13_RISK_REGISTER R-010 | Downgrade probability from High: no fatal redistribution blocker found; residual = GPTK user-fetch fragility, Steam §4.C text, codec content-royalty push. Add new risk: solo clean-room infeasibility for Metal12 (see §6). |
| 16_OPEN_QUESTIONS SPIKE-LEGAL-001 | Mark partially closed: component matrix drafted; remaining items = counsel list (§7). |
| 05_RUNTIME_PROFILE_AND_MANIFEST_SPEC | Provenance record fields (doc 18 §3) should add `sourcePublicationUrl` for LGPL components (Wine fork, DXMT, GStreamer). |

## 6. The Metal12 clean-room decision (required now)

A proprietary Metal12 must not be derived from LGPL sources. The exclusion list is: **vkd3d, vkd3d-proton, and DXMT `src/d3d12/`**. The approved-input list is: Microsoft DirectX-Specs (CC-BY-4.0), DirectX-Headers (MIT), DXC source (NCSA), Apple Metal documentation/WWDC material, and original experimentation.

A solo founder cannot run a two-team clean room (spec team reads copyleft code; implementation team never sees it). The realistic options:

1. **Discipline model (proprietary Metal12):** the founder never reads the excluded sources — including not pasting them into AI-assistant prompts and not debugging "through" DXMT's D3D12 path. Maintain a signed reading log and provenance notes from day one. Weaker evidentiary posture than a true clean room; viable if discipline is absolute and documented. Note that bundling and maintaining DXMT's *D3D11* code is unavoidable and fine — the exclusion is specifically its `src/d3d12/` subtree.
2. **Open model (LGPL Metal12):** license Metal12 LGPL-2.1+, read anything, upstream freely. Kills the proprietary-graphics moat but the strategy doc's moat layers 2–4 (evidence data, lab operations, trust) survive; certified policy/profiles/lab remain proprietary.
3. **Defer model:** postpone Metal12 implementation until a second engineer exists to formalize the clean room; until then D3D11-first catalog only (which is the MVP plan anyway).

Options 1 and 3 compose. Whichever is chosen must be recorded as an ADR before any Metal12 code or any reading of the excluded repos.

## 7. Counsel checklist before first external binary ⚖️

1. macOS SLA full-text review (Rosetta/VideoToolbox use by a commercial compatibility product — expected clean; unverified).
2. Metal Shader Converter tool EULA text (output-shipping is clearly marketed; tool terms unread).
3. GPTK user-fetch flow sign-off, if that flow ships at all.
4. LGPL compliance package mechanics: source-publication pipeline, notice generation, relink capability for Wine/DXMT/GStreamer.
5. Patent counsel on the VideoToolbox-only decode posture and the 2026 content-side royalty campaigns (Access Advance VDP, Avanci Video).
6. Steam SSA §4.C ("Automation") risk memo and acceptance record.
7. Visual Studio Community eligibility check for the redistributable-terms gate (solo founder likely qualifies today; re-check at >$1M revenue / >250 seats).
8. Clean-room protocol documentation for the chosen §6 option.
9. Trademark screen for the eventual product name.

## 8. Source index (primary sources fetched during research)

- Wine COPYING.LIB (wine-mirror/wine); CrossOver source releases (media.codeweavers.com/pub/crossover/source; marzent/winecx)
- FEX-Emu LICENSE + External/ tree; FEX ARM64EC wiki
- DXMT LICENSE + LICENSE.OLD + src/d3d12 tree (3Shain/dxmt)
- MoltenVK LICENSE (KhronosGroup); vkd3d-proton COPYING (HansKristian-Work)
- DXC LICENSE.TXT; DirectX Dev Blog "Open Sourcing DXIL Validator Hash" (Feb 2025); DXC issue #6808
- microsoft/DirectX-Specs LICENSE (CC-BY-4.0); microsoft/DirectX-Headers LICENSE (MIT)
- GStreamer licensing FAQ + legal-information
- Apple GPTK page + EULA quotations (developer.apple.com/games/game-porting-toolkit); WWDC23 session 10124 (shader converter "ship with your game"); WWDC25 Platforms State of the Union (Rosetta statement); Apple third-party trademark guidelines
- CodeWeavers blog: "What's in and what's out for CrossOver 27" (11 June 2026); "Whisky's Legacy" (18 Apr 2025); Whisky maintenance notice quotations
- Microsoft Learn: VS2022 redistribution page; Windows SDK redist list (Oct 2024 update); XAudio2 redistributable page; DirectX End-User Runtime downloads (id=35, id=8109); dotnet/core license-information
- winetricks source (verb implementations for vc_redist/directx/dotnet)
- Steam Subscriber Agreement; Steamworks SDK Access Agreement; Steam Branding Guidelines PDF
- EGS EULA (legal.epicgames.com/store/eula); Legendary/Heroic repos; GamingOnLinux (Apr 2026)
- GOG SDK/FAQ/porting docs
- 17 U.S.C. §1201(f); Copyright Office §1201 report; Directive 2009/24/EC (EUR-Lex); Sega v. Accolade; Sony v. Connectix
- BattlEye statement (24 Sep 2021); EAC Linux toggle coverage; CrossOver 26 anti-cheat coverage (Feb 2026)
- 8th Cir. vacatur coverage (Cooley, Crowell, Sidley memos); California ARL amendment memos (Fenwick, Cooley)
