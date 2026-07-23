# SPIKE-CATALOG-001 — Findings: MVP Game Portfolio

**Version:** 0.2 (research complete)
**Status:** Research findings with proposed decision — pending founder approval
**Date:** 23 July 2026
**Author:** Tim Isaev
**Related:** [Open questions / SPIKE-CATALOG-001](../docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md) · [ADR-0011](../adr/ADR-0011-modern-baseline-only.md) · [Storefront findings](SPIKE-STORE-001-findings.md) · [Publisher/anti-cheat](../docs/17_PUBLISHER_AND_ANTI_CHEAT_INTEGRATION.md)

> Compiled 23 July 2026 from parallel research streams. Confidence per claim: **[P]** primary/Wikipedia-infobox-verified with date, **[S]** secondary/consistent coverage, **[U]** unverified. Access caveats: reddit.com, applegamingwiki.com, codeweavers.com, and pcgamingwiki.com blocked automated fetch — CrossOver vote counts and some compatibility claims are therefore relayed secondary data; demand ranking is directional, not a hard count.

---

## 1. Question

Which 8–12 games maximize user value and technical learning for the MVP while avoiding hard blockers — with backups and a scenario plan (doc 16). Portfolio composition must serve the D3D11-first MVP (ADR-0006): the certified MVP core must lean D3D10/11, with D3D12 titles earmarked as Metal12 vertical-slice targets and at least one Vulkan title exercising MoltenVK.

**Founder direction (23 Jul 2026):** Red Dead Redemption 2 is pinned for portfolio inclusion (subject only to hard-filter facts). It also happens to be the portfolio's best dual-renderer instrument — its D3D12/Vulkan toggle exercises both the future Metal12 path and MoltenVK in one title — and its Rockstar Games Launcher dependency makes it the representative "extra launcher" complexity case. Also founder-pinned (same terms): **The Life and Suffering of Sir Brante** (narrative/UI-heavy lightweight — floor-class candidate) and **Manor Lords** (early-access cadence + city-builder genre coverage); fact-checks pending.

## 2. Hard filters (ADR-0011)

Applied before any scoring: x64-only game executable; primary renderer D3D10/11/12 or Vulkan; officially supports Windows 10 x64+; storefront-managed installation; no required 32-bit-only middleware beyond an approved launcher helper. Additionally treated as disqualifying for *portfolio* purposes (not an ADR filter): a shipped native macOS version — it collapses the demand case even where certification would be technically possible.

## 3. Native-port exclusion list

The 2023–2026 native-port wave (Apple GPTK era) removes these from targeting. Verified native with dates [P unless noted]:

| Title | Native macOS since |
| --- | --- |
| Cyberpunk 2077 Ultimate | 17 Jul 2025 |
| Assassin's Creed Shadows | 20 Mar 2025 (day one) |
| Control | 26 Mar 2025 |
| Palworld | 4 Mar 2025 |
| Civilization VII | 11 Feb 2025 |
| Dead Island 2 | 24 Jul 2025 |
| Frostpunk 2 | 20 Sep 2024 (day one) |
| Hades II | Oct 2024 |
| Civilization VI (Apple Silicon build) | Sep 2024 [S] |
| Death Stranding Director's Cut | 30 Jan 2024 |
| Hollow Knight: Silksong | 4 Sep 2025 (day one) |
| Resident Evil line (RE4make et al.) | 2023–2025 |
| Baldur's Gate 3 · Stray · No Man's Sky | 2023 (pre-wave precedents) |
| Lies of P | day one, 18 Sep 2023 — M1-native re-verified via Apple bundle-ID lookup + live App Store page [P] |
| Total War: Pharaoh | ~2024 [S] |

Control's exclusion is triple-source-verified (Wikipedia, PCGamingWiki infobox, Steam platform flags) and extends publisher-wide: Remedy self-publishes since 2025 and its sequel **Control Resonant** (24 Sep 2026) has its own macOS version announced for later 2026 [S] — treat Remedy titles as native-first going forward.

Palworld's entry carries a sourcing conflict: the Wikipedia-verified 4 Mar 2025 Mac App Store release stands, and one stream's negative checks (Steam `mac:false`; iTunes term-search miss) are non-conclusive by their own admission — an App-Store-only release sets no Steam flag, and the same term search also missed the confirmed Lies of P listing. Treated as excluded; a human App Store check would settle it but nothing depends on it (Palworld fails portfolio scoring on memory regardless).

Unresolved: Riven (2024 remake) — no source reachable this pass [U]; irrelevant to MVP scoring.

Strategic reading: the native wave concentrated on prestige single-player ports and left the long tail — plus most of the 2015–2021 D3D11 back-catalog — untouched. What remains un-ported is exactly MGCR's addressable market.

## 4. Demand evidence

Basis: CrossOver compatibility-center vote counts and CodeWeavers "most requested" callouts (the closest available proxies for real demand), plus coverage density across independent Mac-gaming guides. Directional ranking, not a hard count.

| Rank | Title | Demand evidence | Confidence |
| --- | --- | --- | --- |
| 1 | Helldivers 2 | Most-voted title in CrossOver's entire database (~84–90 votes) | High |
| 2 | Kingdom Come: Deliverance II | CodeWeavers-named "most requested" | High |
| 3 | Age of Empires IV | CodeWeavers-named "most requested" | High |
| 4 | Elden Ring | Dedicated CodeWeavers EAC tips page; no macOS version [P] | High |
| 5 | Red Dead Redemption 2 | Historically most-requested Rockstar title; CrossOver 25 headline; no macOS version [P] | High |
| 6 | Starfield | Bethesda flagship; newly working in CrossOver 26 | High |
| 7 | God of War Ragnarök | Newly working CrossOver 26; major Sony port | High/Med-rank |
| 8 | Diablo IV | Franchise-gap signal (D3 is Mac-native); no macOS version [P] | High |
| 9 | Borderlands 4 | Newly working CrossOver 26; major 2025 release | Med-High |
| 10 | Death Stranding 2 | PC 19 Mar 2026, no Mac announced despite DS1 native precedent | Med-High |
| 11 | FF VII Rebirth | No native Mac; newly working CrossOver 26 | Med-High |
| 12 | Clair Obscur: Expedition 33 | 2025 breakout; 4+ independent "play on Mac" guides | Med-High |
| 13–19 | GTA V · Marvel Rivals · Outer Worlds 2 · MH Wilds · Path of Exile 2 · Darktide · Dragon's Dogma 2 | Mixed signals (see §5 for blocked entries) | Med |

Honorable mentions with thinner evidence: Fallout 76/New Vegas, Witcher 3 next-gen, The Last of Us Part I, Age of Wonders 4, Silent Hill f, Mafia: The Old Country, Company of Heroes 3, Planet Coaster 2.

## 5. The anti-cheat ceiling (expectation-setting)

Per the LEVVVEL database, EAC covers 187/393 tracked anti-cheat titles (47.6%) and BattlEye 50 (12.7%) — together ~60% of anti-cheat-protected games, and **neither vendor has any macOS/Wine opt-in as of July 2026** (consistent with doc 17 §15). Permanently blocked high-demand titles (honest "will not run" list for marketing/support): Fortnite, Valorant, League of Legends (post-Vanguard), CoD/Warzone (Ricochet), Apex, Destiny 2, R6 Siege, PUBG, Tarkov, GTA Online (SP works offline), Marvel Rivals (ACE; NetEase mass-banned Mac emulation users Jan 2025, then reversed), Marathon (BattlEye, Mar 2026 — new debt, not legacy), and — a fact-check correction to the demand list — **Elden Ring**: its EAC is required to *launch the game at all, including fully offline singleplayer* (unlike most EAC titles), so even SP-only certification is impossible without launch tampering, which MGCR's posture forbids. Demand rank 4 notwithstanding, it sits in the vendor-program bucket.

Nuance from CrossOver 26 (Feb 2026): it broke nProtect GameGuard (Helldivers 2, Darktide incl. multiplayer), so kernel-anti-cheat impossibility is now **vendor-specific, not categorical**. For a *certified* runtime this changes little — reverse-engineered accommodation without vendor blessing cannot meet MGCR's certification bar (doc 17) — but it keeps demand-list titles like Helldivers 2 in the "revisit on vendor program" bucket rather than "never."

## 6. Market context

- Steam Hardware Survey: macOS ≈ 2.0–2.35% and flat (Mar–May 2026); Linux overtook macOS. Within the Mac base: M4 19.4%, M1 15.5%, M2 11.4%, M5 8.2% and fastest-growing — demand spans all Apple Silicon generations, supporting ADR-0011's floor-by-memory (not floor-by-chip) posture.
- **Whisky discontinued April 2025** (developer: free tools were "parasitic" on CrossOver's commercially-funded engineering); community successor Sikarugir. The field is CrossOver ($74/yr generalist, no certification model), cloud streaming (GeForce NOW 2,000+ titles — owns the anti-cheat-blocked segment), and Parallels (explicitly weak for modern AAA). A certified-quality runtime has an open lane.
- Consistent genre-gap framing across Mac press: native ports now cover RPG/strategy/indie well; the unserved gap is modern AAA action and shooters — the former is MGCR's addressable segment, the latter is mostly anti-cheat-gated (§5).

## 7. Candidate engineering matrix

### 7.0 Cross-cutting findings from the fact-check streams

- **AVX2 is now a confirmed compatibility axis, not a rumor.** Final Fantasy VII Rebirth and Final Fantasy XVI both **require AVX2 just to boot** [P — diverse stream], and the Yakuza/Dragon-Engine family requires AVX + SSE4.2; the Monster Hunter Wilds AVX2 claim stays community-sourced-only [U]. The stale companion claim that "Rosetta 2 lacks AVX2" (Apple reportedly added it with GPTK2/macOS 15) matters only for the lab-reference path [U — verify]. Hard consequence: **the FEX conformance corpus (SPIKE-CPU-001) must include AVX2/BMI/SSE4.2 coverage**, and per-build instruction-set detection becomes a certification-relevant lab capability.
- **Reference-wiki staleness cuts both ways:** PCGamingWiki still tags Manor Lords as UE 4.27 though the UE5 migration completed Aug 2024 (v0.7.987), and claimed a DOOM: The Dark Ages Denuvo removal that Steam's live API contradicts (Denuvo present today). Live-API verification beats wiki citation for anything decision-bearing.
- **Denuvo-today corrections:** Black Myth: Wukong, Monster Hunter Wilds, and Dragon's Dogma 2 all carry *active* Denuvo as of July 2026 (live-verified), contrary to community assumptions of quiet removal. Denuvo's ~5-activations/day machine limit is a direct lab-automation constraint (fleet activation budgeting) and scores as protection burden 2 in §8.
- **"Finished" is title-specific, not vintage-specific:** Dragon's Dogma 2 (paid expansion Oct 2026 + monetization overhaul), Starfield (PS5 + paid DLC Apr 2026), Monster Hunter Wilds (title updates through 2026, expansion 2027), and S.T.A.L.K.E.R. 2 (engine upgrade + expansion summer 2026) are all still moving targets with correspondingly higher recertification burden.
- **KCD2 may have a native ARM64 Windows build** (PCGamingWiki `windows arm app = true`; storefront unidentified) [U]. If real, it could run under ARM64EC Wine with little or no x86 translation — a uniquely valuable CPU-path test case. Follow up in Phase 0.
- **PSN-account requirements are title-specific and softened through 2025:** God of War Ragnarök mandatory→optional (Jan 2025); Horizon Forbidden West always optional; Ghost of Tsushima requires PSN only for the separate Legends co-op, never the SP campaign.

### 7.1 Per-title matrix

Live candidates only (native-ported and hard-blocked titles live in §3/§5). All entries x64-only with no gameplay 32-bit components [P]. RAM shown min/rec GB; floor verdict: ✓ comfortable at 16 GB · ◐ tight · ✗ realistically needs 24 GB+. Rows from the AAA and addendum streams; diverse-batch rows pending.

| Title | Engine | APIs | Protection / AC today | RAM (floor) | Storefronts | Launcher/account | Bench | Cadence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| The Witcher 3 (next-gen) | REDengine 3 | **D3D11 + D3D12 dual** | none; GOG DRM-free | 6/8 ✓ | Steam·GOG·Epic | none | ✗ | static |
| Sekiro | FromSoft prop. | **D3D11** | none | 4/8 ✓ | Steam | none | ✗ | static |
| God of War (2018) | Santa Monica prop. | **D3D11** | none; GOG DRM-free | 8/8 ✓ | Steam·GOG | PSN not required | ✗ | static |
| God of War Ragnarök | Santa Monica prop. | D3D12 | none | 8/16 ◐ | Steam | PSN optional (since Jan 2025) | ✗ | static |
| Marvel's Spider-Man R. | Insomniac prop. | D3D12 | none | 8/16 ◐ | Steam·Epic | PSN optional | ✗ | static |
| Ghost of Tsushima DC | Sucker Punch prop. | D3D12 | none | 8/16 ◐ (16 GB M4 viable per prior art) | Steam·Epic | PSN for Legends co-op only | ✗ | static |
| Horizon Forbidden West | Decima (Nixxes) | D3D12 | none | 16/16 ✗ | Steam | PSN optional | ✗ | static |
| **Red Dead Redemption 2** ★ | RAGE | **Vulkan + D3D12 dual** | none (launcher is the DRM) | 8/12 ✓ | Steam·Rockstar | **Rockstar Launcher + Social Club mandatory** | **✓ built-in** | static (RDO minor) |
| Starfield | Creation Engine 2 | D3D12 | none | 16/16 ✗ | Steam·MS Store | none on Steam | ✗ | live (PS5 + DLC Apr 2026) |
| Black Myth: Wukong | UE 5.0 | D3D12 | **Denuvo active** | 16/16 ✗ | Steam·Epic | none | ✓ standalone | patching |
| Clair Obscur: Expedition 33 | UE 5.4 | D3D12 | none; GOG DRM-free (Sep 2025) | 8/16 ◐ (one 25 GB-spike area) | Steam·GOG·Epic·MS/Game Pass | none | ✗ | patching |
| Kingdom Come: Deliverance II | CryEngine V | D3D12 | none; GOG DRM-free | 16/32 ✗ | Steam·GOG·Epic·MS | none | ✗ | patching; ARM64 build claim [U] |
| S.T.A.L.K.E.R. 2 | UE 5.1→5.5 | D3D12 | none; GOG DRM-free | 16/32 ✗ | Steam·GOG·Epic·MS | none | ✗ | heavy live (expansion 2026) |
| Monster Hunter Wilds | RE Engine | D3D12 | **Denuvo active** | 16/16 ✗ | Steam | none | ✓ standalone | live (expansion 2027) |
| Dragon's Dogma 2 | RE Engine | D3D12 | **Denuvo active** | 16/16+8 VRAM ✗ | Steam | none | ✗ | live (expansion Oct 2026) |
| Diablo IV | prop. (unnamed) | D3D12 | none; **always-online, no offline mode** | 8/16 ◐ | Battle.net·Steam | Battle.net mandatory | ✗ (confirmed absent) | live seasons |
| Borderlands 4 | UE 5.5 | D3D12 | **Denuvo + Symbiote** (user-mode) | 16/32 ✗ | Steam | none | ✗ | live-adjacent |
| The Outer Worlds 2 | UE 5.4 | D3D12 | none | 16/16 ✗ | Steam·MS·Battle.net | Game Pass ties | ✗ | static |
| Darktide | Stingray | D3D12 | none (EAC removed Jun 2024); **always-online** | 8/16 ◐ | Steam·MS | Fatshark servers mandatory | ✗ | live quarterly |
| Death Stranding 2 | Decima (Nixxes) | D3D12 | none | 16/16 ✗ | Steam·Epic·others | PSN unverified | ✗ | static |
| DOOM Eternal | id Tech 7 | **Vulkan only** | none (Denuvo removed Sep 2023); GOG DRM-free | 8/8 ✓ | Steam·GOG·MS | Bethesda acct SP-bypassable; none on GOG build | ✗ (intro-skip arg) | static |
| DOOM: The Dark Ages | id Tech 8 | Vulkan only | **Denuvo active (live-verified today)** | 16+/32+ ✗ | Steam·MS | unclear | ✓ built-in | live (DLC 2026) |
| Persona 5 Royal | GFD (Atlus) | **D3D11** | **Denuvo active** | 8/8 ✓ | Steam·MS | none | ✗ | static |
| Metaphor: ReFantazio | GFD | **D3D11** | **Denuvo active** | 6/8 ✓ | Steam·MS | none | ✗ | static |
| NieR: Automata | Platinum Engine | **D3D11** | none (Denuvo removed Jul 2021) | 4/8 ✓ | Steam·MS | none | ✗ (documented intro-skip) | static |
| Yakuza: Like a Dragon | Dragon Engine | **D3D11** | Steam has Denuvo; **GOG build DRM-free** | 8/8 ✓ | Steam·GOG·MS | none | ✗ | static |
| Like a Dragon: Infinite Wealth | Dragon (D3D12 gen) | D3D12 | **Denuvo active** | 8/16 ◐ | Steam·MS | none | ✗ | static |
| Hogwarts Legacy | UE 4.27 | D3D12 | **Denuvo active (never removed)** | ~20–24 combined ✗ | Steam·Epic·MS | WB optional | ✗ | static |
| Forza Horizon 5 | ForzaTech | D3D12 | none | 8/16 ◐ | Steam·MS·Amazon | **Xbox acct + broadband even solo** | [U] | maintenance (FH6 shipped May 2026) |
| Silent Hill 2 (2024) | UE 5.1 | D3D12 | none — DRM-free on Steam and GOG | ~24 combined ✗ | Steam·GOG·Epic | none | ✗ (file-edit skip) | static |
| Armored Core VI | FromSoft prop. | D3D12 | Arxan + **EAC (SP scope unconfirmed)** | 12/12 ◐ | Steam | unconfirmed | ✗ | static |
| Split Fiction | UE5 | D3D12 | none | 16/16 ✗ | Steam·EA·Epic | EA account; Friend's Pass needs online | ✗ | static |
| It Takes Two | UE4 (AngelScript fork) | **D3D11** | none (Denuvo + EA launcher both removed May 2024) | 8/16 ◐ | Steam·EA | EA acct linked | ✗ | static |
| Cities: Skylines II | Unity HDRP | D3D11 [low confidence] | none | 8/16+ ◐ | Steam·MS | none | ✗ | patching; studio handover 2026 |
| Age of Empires IV | Essence 5 (Relic) | D3D12 | none found; **EAC present (SP scope disputed)** | 8/16 ◐ | Steam·MS | **MS account even on Steam** | ✗ (lockstep replays) | active DLC |
| Path of Exile 2 | GGG prop. | D3D11(dep)·D3D12·Vulkan | none; **always-online, server-authoritative** | 8/16 ◐ | Steam·Epic·site | GGG acct + connection mandatory | ✗ | early access, live |
| Enshrouded | Holistic (Keen) | **Vulkan only** | none; broadband is a min-req | 16/16 ✗ | Steam | none | ✗ | EA → 1.0 on 15 Oct 2026 |
| FF VII Rebirth | UE 4.26 | D3D12 | none; **AVX2 required to boot** | 16/16 ✗ | Steam·Epic·MS | none | ✗ | static |
| FF XVI | prop. (CBU3) [U] | D3D12 | none (Denuvo removed Mar 2025); AVX2 to boot | 16/16 ✗ | Steam·Epic·MS·Amazon | none | ✗ | static |
| Dark Souls III | FromSoft prop. | **D3D11** | **none at all** (no EAC — that's Elden Ring) | 4/8 ✓ | Steam | none | ✗ | static |
| **Sir Brante** ★ | Unity 2018.3 | **D3D11** | none; GOG DRM-free | 1/– ✓ | Steam·GOG·Epic·more | none | ✗ | static |
| **Manor Lords** ★ | UE5 (migrated Aug 2024) | D3D12 | none; GOG DRM-free | 8/12 ✓ | Steam·GOG·Epic·MS | none | ✗ | **early access** (no 1.0 date), active |

Final coverage: 42 live candidates fact-checked (plus 3 researched-and-excluded natives and the §5 blocked set). D3D11-capable candidates: Witcher 3 (dual), Sekiro, God of War 2018, Persona 5 Royal, Metaphor, NieR, Yakuza: Like a Dragon, It Takes Two, Dark Souls III, Sir Brante (+ Cities: Skylines II low-confidence, PoE2 deprecated-path) — the ≥6-title D3D11 core constraint is satisfiable with margin. Vulkan-capable: DOOM Eternal (pure), RDR2 (default), Enshrouded, DOOM Dark Ages, PoE2.

## 8. Scoring and ranked portfolio

Scoring rubric (0–5 per criterion; weights sum to 100%):

| Criterion | Weight | Anchors |
| --- | --- | --- |
| Demand (§4 evidence) | 25% | 5 = top-5 ranked signal · 3 = recurring coverage · 1 = thin |
| Technical learning value | 15% | Marginal engine/API/middleware coverage the portfolio lacks without this title |
| Automation determinism | 15% | 5 = built-in benchmark or fixed intro, fully offline · 1 = always-online/randomized |
| Protection burden | 15% | 5 = none · 4 = Steam DRM only · 2 = Denuvo/user-mode anti-tamper (lab activation budget) · 0 = active anti-cheat |
| Memory fit at 16 GB floor | 10% | 5 = rec ≤ 8 GB · 3 = rec 16 GB with settings headroom · 1 = min 16 GB (needs 24 GB+ class) |
| Storefront/launcher complexity | 10% | 5 = Steam-clean or GOG DRM-free · −1 per extra launcher/account layer |
| Update cadence | 5% | 5 = finished title · 1 = live-service seasons |
| Publisher opportunity | 5% | Realistic design-partner path (SPIKE-PUB-001) |

Portfolio composition constraints (applied after per-title scoring; the portfolio is an instrument, not a leaderboard):

- ≥ 6 titles certifiable on the D3D11 path — the MVP certified core (ADR-0006);
- 2–3 D3D12 titles carried as **Metal12 vertical-slice targets** (lab titles, not MVP-certified);
- ≥ 1 Vulkan-primary title exercising MoltenVK;
- ≥ 4 distinct engine families across the set;
- ≥ 2 titles comfortable on the 16 GB floor machine (floor-class reference titles);
- ≥ 1 title with a built-in benchmark as the lab-determinism anchor (SPIKE-LAB-001);
- Red Dead Redemption 2 pinned (founder direction, §1).

Weighted scores for the titles that survive hard filters and aren't excluded by §7.1 facts (titles failing on memory ✗ + Denuvo + always-online combinations are scored out by inspection; rationale in §9.3):

| Title | Demand .25 | Learning .15 | Determinism .15 | Protection .15 | Memory .10 | Storefront .10 | Cadence .05 | Publisher .05 | **Weighted** |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Red Dead Redemption 2 ★ | 5 | 5 | 5 | 4 | 4.5 | 3 | 5 | 2 | **4.45** |
| DOOM Eternal | 3.5 | 5 | 3.5 | 5 | 5 | 5 | 5 | 2 | **4.25** |
| The Witcher 3 | 3 | 5 | 3 | 5 | 5 | 5 | 5 | 3 | **4.10** |
| God of War (2018) | 4 | 3.5 | 3 | 5 | 5 | 5 | 5 | 2 | **4.08** |
| Sekiro | 3.5 | 4 | 3 | 5 | 5 | 5 | 5 | 2 | **4.03** |
| Kingdom Come: Deliverance II | 5 | 4 | 3 | 5 | 1 | 5 | 3 | 4 | **4.00** |
| NieR: Automata | 3 | 3.5 | 4 | 5 | 5 | 4.5 | 5 | 2 | **3.93** |
| Manor Lords ★ | 3.5 | 4 | 3 | 5 | 5 | 5 | 1 | 4 | **3.93** |
| Ghost of Tsushima DC | 4 | 4 | 3 | 5 | 3 | 4.5 | 5 | 2 | **3.90** |
| Yakuza: Like a Dragon | 3 | 4 | 3 | 4.5 | 5 | 5 | 5 | 3 | **3.88** |
| Marvel's Spider-Man R. | 4 | 3.5 | 3 | 5 | 3 | 4.5 | 5 | 2 | **3.83** |
| Dark Souls III | 3.5 | 2.5 | 3 | 5 | 5 | 5 | 5 | 2 | **3.80** |
| Clair Obscur: Expedition 33 | 4 | 3 | 3 | 5 | 3 | 5 | 4 | 3 | **3.80** |
| Persona 5 Royal | 4 | 3.5 | 3 | 2 | 5 | 4.5 | 5 | 3 | **3.63** |
| Metaphor: ReFantazio | 3 | 2 | 3 | 2 | 5 | 4.5 | 5 | 3 | **3.30** |
| The Life and Suffering of Sir Brante ★ | 1 | 3 | 4 | 5 | 5 | 5 | 5 | 2 | **3.40** |

Composition-constraint check for the §9 portfolio: D3D11 core = 8 ✓ (≥6); Metal12 targets = 3 ✓; Vulkan = 2 ✓ (DOOM Eternal pure + RDR2 default); engine families = 12 across 13 titles ✓ (≥4); floor-class ✓ (Sekiro, NieR, DS3, Brante, Witcher 3, YLAD, P5R, Manor Lords); benchmark anchor ✓ (RDR2 built-in); all three founder pins honored ✓.

## 9. Proposed decision

### 9.1 The portfolio (13 titles: 1 smoke test + 9 certification track + 3 Metal12 lab targets)

**Title #0 — pipeline smoke test (certified, trivially):**
0. **The Life and Suffering of Sir Brante** ★ — Unity/D3D11/1 GB/GOG-DRM-free; the end-to-end pipeline validation title: profile → install → policy → launch → save → evidence, at near-zero performance risk.

**MVP certified core (D3D11 + MoltenVK track, ships with MVP):**
1. **Sekiro** — flagship action; FromSoft engine; clean everything.
2. **The Witcher 3** — flagship RPG; the D3D11↔D3D12 differential instrument; GOG-dual.
3. **God of War (2018)** — flagship Sony; D3D11; GOG-dual; PSN-free.
4. **NieR: Automata** — best prior art of the entire pool (ProtonDB 0.91; documented deterministic intro-skip); D3D11.
5. **Yakuza: Like a Dragon** — Dragon Engine; **certify the GOG DRM-free build**, Steam-Denuvo build as differential case.
6. **Persona 5 Royal** — highest-demand JRPG; D3D11; the one Denuvo title in the core (accepted trade, activation-budgeted in lab).
7. **Dark Souls III** — evergreen; zero DRM/AC; floor-trivial.
8. **DOOM Eternal** — the MoltenVK validator (Vulkan-only, id Tech 7); Denuvo removed; certify GOG build.
9. **Red Dead Redemption 2** ★ — Vulkan default + D3D12 alternate; built-in benchmark = lab determinism anchor; Rockstar-launcher complexity case; SP certification, RDO in disclosed limitations.

**Metal12 vertical-slice lab targets (not MVP-certified; graduate with Metal12 slices A→C):**
10. **Manor Lords** ★ — lightest clean D3D12 title in the pool; slice-A bring-up target; early-access cadence exercises recertification machinery; GOG-dual.
11. **Ghost of Tsushima DC** — clean Sony D3D12; 16 GB-viable per prior art; PSN only for the separate co-op mode; slice B.
12. **Kingdom Come: Deliverance II** — demand #2 overall; CryEngine V; GOG-dual; possible ARM64 Windows build [U]; memory-gated to 32 GB hosts; slice C.

### 9.2 Backups (ordered, with the slot they'd fill)

Metaphor: ReFantazio (P5R alternate, same GFD engine, lighter); Marvel's Spider-Man Remastered (GoT alternate); Clair Obscur: Expedition 33 (KCD2 alternate, GOG-dual, lighter); It Takes Two (adds co-op genre + EA-ecosystem coverage on D3D11); Silent Hill 2 (memory-gated to 24 GB class); Enshrouded (second Vulkan title — revisit at 1.0, 15 Oct 2026); God of War Ragnarök (Sony D3D12, now PSN-optional).

### 9.3 Notable exclusions (recorded reasons, revisit triggers)

- **Elden Ring** — EAC required even offline (§5); revisit only on a vendor program.
- **Age of Empires IV** — demand #3, but EAC with disputed SP scope + Microsoft account on every storefront; investigate EAC scope in Phase 0; revisit if SP is EAC-free.
- **Diablo IV, Darktide** — always-online live-service; deferred to compatibility-operations era (Phase 3+).
- **Monster Hunter Wilds, Dragon's Dogma 2, Black Myth: Wukong, Hogwarts Legacy, Borderlands 4, DOOM: The Dark Ages** — active Denuvo (live-verified) combined with memory ✗ and/or live cadence; each gets a revisit trigger on Denuvo removal (precedents: FFXVI, DOOM Eternal, It Takes Two, NieR all shed Denuvo eventually).
- **FF VII Rebirth, FF XVI** — memory ✗ + AVX2-to-boot (CPU-path dependency); FFXVI additionally carries a named CrossOver "Unplayable" prior-art flag; strong future targets once FEX AVX2 conformance and 24 GB-class certification exist.
- **Forza Horizon 5** — Xbox account + broadband even solo, CrossOver "Unplayable" flag, succeeded by FH6.
- **Starfield, S.T.A.L.K.E.R. 2, Split Fiction, The Outer Worlds 2, Death Stranding 2, Horizon Forbidden West, Silent Hill 2** — memory ✗ on the 16 GB floor; natural first wave for the 24 GB+ certification class (M12-004).
- **Path of Exile 2, Enshrouded** — early access; PoE2 additionally always-online.
- **Cities: Skylines II** — CrossOver "Limited Functionality" + studio-handover risk + renderer uncertainty.

### 9.4 Scenario plan sketch (feeds SPIKE-LAB-001 and doc 07)

Every certification-track title gets: cold-install → first-launch → menu → deterministic scene (RDR2: built-in benchmark; NieR: documented intro-skip; others: scripted fixed-input intros) → save/load → clean exit, captured against the Windows reference oracle. Witcher 3 runs the same scenario on both renderers; YLAD and DOOM Eternal run GOG-vs-Steam build differentials; Manor Lords runs the update-churn drill each early-access patch.

### 9.5 Storefront cross-check (closes SPIKE-STORE-001 open item 4)

All 13 titles are on Steam. Seven are also on GOG (Witcher 3, GoW 2018, YLAD, DOOM Eternal, Sir Brante, Manor Lords, KCD2 — plus backup E33), five of those with DRM-free builds we'd certify directly. This materially supports the Steam-first / GOG-at-MVP+1 sequencing proposed in the storefront findings.

### 9.6 Open items

| # | Item | Where it lands |
| --- | --- | --- |
| 1 | KCD2 `windows arm app` PCGW field verification | pending (research agent) — pure curiosity value for the CPU path |
| 2 | AoE IV EAC singleplayer-scope | Phase 0 investigation; gates a high-demand backup |
| 3 | Palworld Mac App Store human check | optional; nothing depends on it |
| 4 | FH5/FFXVI "Unplayable" prior-art flags | re-test under MGCR stack when it exists — CrossOver results don't transfer 1:1 |
| 5 | Rosetta AVX2 status (macOS 15+) | SPIKE-CPU-001 lab-reference note |
| 6 | Benchmark-mode verification for Forza-class titles | SPIKE-LAB-001 intake |
