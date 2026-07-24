# SPIKE-LEGAL-001 — Counsel Brief: Nine-Item Review Before First External Binary

**Version:** 0.1 (draft for founder review, then counsel)
**Status:** Engineering work product — founder must review before sending to counsel
**Date:** 24 July 2026
**Author:** Tim Isaev
**Related:** [Preliminary findings](SPIKE-LEGAL-001-preliminary-findings.md) · [Legal plan](../docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md) · [ADR-0012 clean room](../adr/ADR-0012-metal12-provenance-and-clean-room.md) · [Risk register R-010/R-036](../docs/13_RISK_REGISTER.md) · [PROVENANCE log](../../PROVENANCE.log)

> **This is not legal advice.** It is a structured brief that turns the nine-item
> checklist in [SPIKE-LEGAL-001 §7](SPIKE-LEGAL-001-preliminary-findings.md) into
> questions a qualified attorney can act on. Each item states what we do, the precise
> question, our **preliminary (non-lawyer) position** for counsel to confirm or correct,
> the primary sources we have already reviewed, and the specific answer we need. The goal
> is to make the engagement fast and cheap: counsel confirms or redirects our reasoning
> rather than starting from a blank page.

---

## 1. How to use this brief

1. **Founder reviews this document** and corrects anything that misstates the product or our intent.
2. **Select counsel** (see §3). Send this brief plus the [preliminary findings](SPIKE-LEGAL-001-preliminary-findings.md) as the engagement packet.
3. **Scope the engagement as a fixed written memo**, item by item, not an open retainer — the questions are bounded and mostly confirmatory.
4. **Capture answers** back into a memo that closes GitHub issue #13 and moves deliverable D10 to complete. Each §5 item lists the "green light" that counts as answered.

This brief deliberately gives counsel our reasoning and our sources. For a solo founder, an attorney who can *review a well-formed position* bills far less than one asked to research from scratch.

## 2. What the product is (context for counsel)

Alloy is a **commercial compatibility product for Apple Silicon Macs** that runs unmodified Windows x64 games. It combines a thin fork of Wine (Windows API layer), the FEX-Emu CPU translator (x64→ARM64), and Metal-native graphics providers, packaged as a signed, notarized, content-addressed immutable runtime distributed under a Developer ID.

Three facts shape every question below:

- **It builds on open-source components** — Wine, FEX, DXMT, GStreamer, MoltenVK — several under LGPL, which carries source-publication and relink obligations.
- **It uses macOS system services as intended** — Rosetta 2 (bootstrap/reference only, never a production dependency), VideoToolbox/AudioToolbox for media decode, standard JIT entitlements.
- **It never circumvents protection or intercepts credentials** — it reads unencrypted local storefront metadata and launches official clients; it strips no DRM. This keeps the design largely outside DMCA §1201 (see [preliminary findings §3](SPIKE-LEGAL-001-preliminary-findings.md)).

A separate, strategically important component — **Metal12**, our own proprietary D3D12-on-Metal implementation — must be built without contamination from copyleft D3D12 sources. That constraint is item 8 and is already being practiced today.

## 3. Counsel specialties and suggested engagement

| Role | Covers items | Notes |
| --- | --- | --- |
| **Lead: technology transactions / open-source licensing attorney** | 1, 2, 3, 4, 6, 7, 8 | Quarterbacks the engagement; OSS-license fluency is essential (LGPL relink is the hard one). |
| **Patent counsel** | 5 | Codec pool / content-royalty exposure; can be a specialist within the same IP firm. |
| **Trademark counsel** | 9 | Knock-out search and filing strategy; usually the same IP firm. |

An IP/technology boutique, or the tech-transactions group of a general firm with IP specialists, can cover all three. Prefer a firm with **open-source software and video-game/interop clients** — the LGPL-relink and reverse-engineering questions reward domain familiarity.

## 4. Priority tiers (what gates what)

| Tier | Meaning | Items |
| --- | --- | --- |
| **A — constrains practice now** | Affects what the founder may do today; the evidentiary record builds continuously from now | 8 (clean-room protocol) |
| **B — hard gate before any external binary** | Getting these wrong is infringement or a naming conflict; must clear before first release | 4 (LGPL compliance), 9 (trademark clearance) |
| **C — gate before first binary, lower risk** | Expected clean; confirmation needed | 1 (macOS SLA), 2 (shader-converter output), 5 (codec decode), 6 (Steam automation) |
| **D — conditional / low urgency** | Only if a specific flow ships, or has alternatives | 3 (GPTK user-fetch — currently lab-only), 7 (VS eligibility) |

None of the nine block **Phase-0 internal lab work**; all gate the **first externally distributed binary** (risk [R-010](../docs/13_RISK_REGISTER.md)). Item 8 is Tier A only because its protective value comes from being reviewed early, while the provenance record is still short.

## 5. The nine items

### Item 1 — macOS SLA use by a commercial compatibility product (Tier C)

- **What we do:** Run on macOS; invoke Rosetta 2 for bootstrap/reference execution only (never production, per [ADR-0005](../adr/ADR-0005-fex-arm64ec-execution-path.md)); use VideoToolbox/AudioToolbox for media decode.
- **Question for counsel:** Does the macOS Software License Agreement permit a commercial third-party product to (a) invoke Rosetta 2 for bootstrap/reference execution and (b) use VideoToolbox/AudioToolbox for game-media decode, with no use restriction violated?
- **Our preliminary position:** Clean — these are documented system APIs used as intended; Rosetta is optional and non-production.
- **Sources reviewed:** macOS SLA (full text unverified — the specific gap); Apple developer documentation.
- **Green light:** Written confirmation neither use violates the SLA, or the specific clauses to design around.

### Item 2 — Metal Shader Converter output-shipping (Tier C)

- **What we do:** Convert shaders with Apple's Metal Shader Converter and ship the resulting `.metallib` output in the product.
- **Question for counsel:** Do the Metal Shader Converter tool's license terms permit shipping its output in a commercial product? Apple markets "ship with your game," but the tool's own EULA text is unread.
- **Our preliminary position:** Output-shipping is clearly marketed (WWDC23 session 10124); the grant is expected to match, pending the actual EULA text.
- **Sources reviewed:** WWDC23 session 10124; Apple developer download terms (tool EULA unread — the gap).
- **Green light:** Confirmation the EULA grant matches the marketing (converted output is redistributable).

### Item 3 — GPTK user-fetch flow, if it ships at all (Tier D, conditional)

- **What we do:** Today, GPTK/D3DMetal is **lab-only** ([D-021](../docs/14_DECISION_LOG.md)). This item matters only if Alloy later ships a user-initiated fetch (user accepts Apple's EULA and downloads GPTK under their own Apple ID — the Whisky/Mythic pattern).
- **Question for counsel:** If Alloy implements such a user-fetch flow, is that defensible for a commercial product given GPTK's non-commercial distribution limit? What disclosures/UX would be required, or should the flow simply not ship?
- **Our preliminary position:** The Whisky pattern is tolerated, not blessed, and clashes with our one-click signed-immutable-runtime thesis; we have kept GPTK lab-only for now.
- **Sources reviewed:** GPTK EULA quotations; CodeWeavers "Whisky's Legacy" (18 Apr 2025); Apple GPTK page.
- **Green light:** Either "defensible with disclosures X/Y" or "do not ship it" — so we know whether the flow is ever an option.

### Item 4 — LGPL compliance for a signed, immutable runtime (Tier B, hard gate)

- **What we do:** Bundle Wine (fork), DXMT, and GStreamer — all LGPL-2.1-or-later. Plan: publish fork source + diffs per release, generate notices, and keep a dynamic-linking boundary so a user can substitute their own build of the LGPL library.
- **Question for counsel:** Does this pipeline satisfy LGPL-2.1+ §6 when the runtime is **signed, notarized, immutable, and content-addressed**? Specifically, does immutability conflict with the user's relink right, and if so, what mechanism reconciles them (e.g., published relink instructions, an unsigned rebuild path, documented object availability)?
- **Our preliminary position:** The CrossOver model (published fork source + diffs, dynamic boundary) is the precedent; the genuine tension is our signed-immutable thesis versus LGPL's relink guarantee.
- **Sources reviewed:** Wine `COPYING.LIB`; CrossOver source releases (marzent/winecx); LGPL-2.1 text; DXMT `LICENSE` (relicensed MIT→LGPL after v0.80); GStreamer licensing FAQ.
- **Green light:** Confirmation the pipeline satisfies §6, or the exact mechanism required to reconcile immutability with relink. This is the highest-consequence item — shipping LGPL code out of compliance is infringement.

### Item 5 — Codec decode posture and 2026 content-royalty campaigns (Tier C)

- **What we do:** Decode all media (H.264/HEVC/VC-1/AAC) exclusively through Apple's VideoToolbox/AudioToolbox. We bundle no codec and distribute no content.
- **Question for counsel:** Does routing all decode through Apple's system frameworks discharge our patent obligations, given the 2026 content-side royalty campaigns (Access Advance VDP, Avanci Video)? Is there residual content-royalty exposure for a product that merely passes game media to the OS decoder?
- **Our preliminary position:** Clean — we are neither a codec vendor nor a content distributor; HEVC is dual-pool and active, and the 2026 content-royalty push is unsettled, so patent counsel should confirm.
- **Sources reviewed:** Via LA and Access Advance pool terms; Avanci Video; Apple VideoToolbox documentation.
- **Green light:** Confirmation the system-decoder-only posture carries no material patent/royalty liability, or identification of any content-royalty exposure and how to disclaim it.

### Item 6 — Steam SSA §4.C "Automation" (Tier C)

- **What we do:** Launch the official Steam client, read local unencrypted `appmanifest_*.acf` files, use `steamcmd`. We never intercept credentials.
- **Question for counsel:** Does this integration run afoul of Steam Subscriber Agreement §4.C ("Automation")? What acceptance or disclosure posture minimizes risk?
- **Our preliminary position:** The design stays clear of credential interception; §4.C's "Automation" language is the residual gray area.
- **Sources reviewed:** Steam Subscriber Agreement; Steamworks SDK Access Agreement; Steam Branding Guidelines.
- **Green light:** A short risk memo classifying our specific integration against §4.C, with an accept-or-adjust recommendation we can record.

### Item 7 — Visual Studio Community / redistributable eligibility (Tier D)

- **What we do:** Use Visual Studio Community and Microsoft "Distributable Code" redistributables. Solo founder, pre-revenue.
- **Question for counsel:** Does the founder/company qualify for VS Community and the redistributable-code license today, and what revenue/seat threshold triggers re-licensing?
- **Our preliminary position:** A solo founder likely qualifies today; re-check at >$1M revenue or >250 seats.
- **Sources reviewed:** VS2022 redistribution page; VS Community license terms.
- **Green light:** Confirmation of current eligibility and the specific threshold that ends it. (Low urgency — permissive toolchains exist as alternatives.)

### Item 8 — Clean-room protocol for proprietary Metal12 (Tier A, constrains practice now)

- **What we do:** Build Metal12 (proprietary D3D12-on-Metal) **without** reading excluded copyleft sources — vkd3d, vkd3d-proton, and DXMT `src/d3d12/`. As a solo founder who cannot staff a two-team clean room, we use the **discipline model** of [ADR-0012](../adr/ADR-0012-metal12-provenance-and-clean-room.md): a fixed exclusion list, spec-only approved inputs (DirectX-Specs, DirectX-Headers, DXC source, Apple docs), an append-only [provenance log](../../PROVENANCE.log), and rules that also bar pasting excluded sources into AI assistants. This discipline is **already being practiced** (provenance log active since 23 July 2026).
- **Question for counsel:** Does the ADR-0012 discipline model give a defensible evidentiary posture against a future similarity/derivation claim on Metal12, for a solo founder? What additional documentation or process would strengthen it — and is proprietary Metal12 advisable at all solo, versus the open-source (LGPL) fallback?
- **Our preliminary position:** Weaker than a true two-team clean room but viable if discipline is absolute and documented; the fallback is open-sourcing Metal12 (ADR-0012 alternative 1), which preserves the non-graphics moat layers.
- **Sources reviewed:** ADR-0012; PROVENANCE.log; U.S. clean-room precedent (counsel to advise — e.g., *Sega v. Accolade*, *Sony v. Connectix* on interop, and derivation-claim defense practice).
- **Green light:** Counsel review of ADR-0012 as adequate (with any hardening), **or** a determination that solo proprietary Metal12 is too risky → adopt the open (LGPL) model. Review is Tier A because the protective record is being built continuously from today; an early blessing (or early redirect) maximizes its value.

### Item 9 — Trademark clearance and registration for "Alloy" (Tier B, hard gate)

- **What we do:** Use "Alloy" as the product name (adopted 23 July 2026, [D-021](../docs/14_DECISION_LOG.md)). It is **already in use as the public GitHub repository name** and the internal product name.
- **Question for counsel:** Is "Alloy" clear for software/games (Nice classes 9, 41, 42), given known adjacent-software "Alloy" marks (a marketing-automation company and an identity-verification company)? What is the filing strategy — and does the name's existing presence on a public code repository affect clearance, priority, or anyone else's rights?
- **Our preliminary position:** A knock-out search across classes 9/41/42 is needed; adjacent "Alloy" marks exist; clearance should precede public/commercial use, with filing thereafter and defensive domain/handle acquisition (`alloyplay.com` was unregistered on 23 July 2026).
- **Sources reviewed:** The adjacent marks the founder identified; USPTO search to be performed by counsel.
- **Green light:** A clearance opinion (clear / clear-with-narrowing / conflict) plus a filing recommendation, and an explicit note on whether the public-repo use changes anything. Tier B because public use is arguably already underway.

## 6. Constraints to hold pending answers

Until counsel responds, the following remain in force (they cost nothing and preserve every option):

- **No external binary distribution** of any kind — internal lab use only (gates items 1, 2, 4, 5, 6).
- **Continue the ADR-0012 discipline exactly** — do not read or paste any excluded source (vkd3d, vkd3d-proton, DXMT `src/d3d12/`) into any human or AI context; keep the provenance log append-only (item 8).
- **No user-fetch GPTK flow** — GPTK stays lab-only (item 3).
- **Avoid the word "certified" in any public copy** until the evidence lab exists; use "tested against [exact list]" (adjacent to item 9 and FTC substantiation, [preliminary findings §4](SPIKE-LEGAL-001-preliminary-findings.md)).
- **No commercial/public launch under the "Alloy" name** beyond the existing repository until clearance (item 9).

## 7. Source index

The primary-source list compiled during research is in
[SPIKE-LEGAL-001 §8](SPIKE-LEGAL-001-preliminary-findings.md). Send that section to counsel alongside this brief; it documents exactly which license texts, statutes, and vendor pages we have already read, so counsel need not re-fetch them.
