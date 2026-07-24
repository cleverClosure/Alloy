# SPIKE-LEGAL-001 — Pre-counsel risk assessment (nine-item review)

**Status:** Recorded verbatim — **not legal advice, not counsel's answer to [#13](https://github.com/cleverClosure/Alloy/issues/13)**
**Received:** 24 July 2026 · **Recorded by:** Tim Isaev
**Source:** [issue #13 comment](https://github.com/cleverClosure/Alloy/issues/13#issuecomment-5073374320)
**Related:** [Counsel brief](SPIKE-LEGAL-001-counsel-brief.md) · [Preliminary findings](SPIKE-LEGAL-001-preliminary-findings.md) · [Legal plan](../docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md) · [ADR-0012](../adr/ADR-0012-metal12-provenance-and-clean-room.md)

> **What this is.** A risk assessment obtained by the founder against the nine-item
> [counsel brief](SPIKE-LEGAL-001-counsel-brief.md), reproduced below exactly as received.
> It is recorded here because a GitHub comment is not a durable engineering record.
>
> **What this is not.** It states its own limits, and they are binding on how we use it:
> *"This is a conservative, U.S.-focused risk assessment, not an attorney-client opinion,
> and it creates no privilege."* It also records that the reviewer did **not** read the
> linked ADR, provenance log, source tree, SBOM, accepted package EULAs, or compiled
> binaries, and that it assumes Developer ID distribution rather than the Mac App Store
> or a cloud model.
>
> **Therefore deliverable D10 remains incomplete and issue #13 stays open.** D10 requires
> qualified counsel engaged and the nine items answered. This assessment sharpens the
> brief and tightens what we may do today; it does not discharge the gate.
>
> **What it changed.** The corrections it makes to our preliminary positions are folded
> into the [counsel brief](SPIKE-LEGAL-001-counsel-brief.md) §4–§6 and into the binding
> engineering constraints in [doc 18](../docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md).
> Four items moved: **3** (GPTK user-fetch) closed as do-not-ship, **5** (codecs)
> escalated from "expected clean" to a release gate, **7** (Visual Studio) had its
> threshold language corrected, and **9** (trademark) escalated from "commission a
> search" to "rename before launch".

---

## SPIKE-LEGAL-001 — Practical Founder Verdicts

### Overall verdict

**Do not distribute an external binary yet—not even to a closed beta group.** Continue internal development, but treat any copy sent outside your controlled machines as an external release.

The brief’s basic priority structure is sound: LGPL compliance and trademark clearance are genuine release gates, while the Metal12 clean-room protocol must operate continuously. I would make three material changes:

1. **Upgrade codec licensing from Tier C to a hard gate** unless patented-codec playback is disabled.
2. **Close GPTK user-fetch as “do not ship,”** rather than spending time trying to justify it.
3. **Rename “Alloy” now,** rather than merely commissioning a more detailed search.

That is consistent with the brief’s existing instruction to prohibit external binaries, continue the clean-room discipline, keep GPTK lab-only, and avoid further launch activity under “Alloy.”

This is a conservative, U.S.-focused risk assessment, not an attorney-client opinion, and it creates no privilege. It assumes Developer ID distribution to users’ lawfully licensed Apple Silicon Macs, not the Mac App Store or a cloud/service-bureau model. I have reviewed the counsel brief, but not the linked ADR, provenance log, source tree, SBOM, accepted package EULAs, or compiled binaries.

| Item | Verdict | Founder decision |
|---|---|---|
| 1. macOS SLA/system services | **Conditional green** | Invocation appears defensible; do not redistribute Apple components |
| 2. Metal Shader Converter output | **Conditional green** | Ship output only after preserving and reviewing the exact package terms |
| 3. GPTK user-fetch | **Red** | Do not ship |
| 4. LGPL immutable runtime | **Red until implemented and tested** | No external binary until users have a real relink/substitution path |
| 5. Codec decoding | **Red/amber** | Obtain written coverage/no-license position or disable affected playback |
| 6. Steam automation | **Amber** | Local read-only discovery is acceptable; automated Steam interaction is not |
| 7. Visual Studio Community | **Green today** | Eligible on the stated facts; correct the threshold language |
| 8. Metal12 clean room | **Amber, continuous** | Proceed internally under strengthened evidence controls |
| 9. “Alloy” trademark | **Red** | Rename before launch |

---

### 1. macOS SLA, Rosetta 2, VideoToolbox and AudioToolbox

#### Verdict: **Conditional go**

I found no provision in the reviewed macOS licensing text that specifically prohibits a commercial application from invoking Rosetta or Apple’s media frameworks in the manner described. The macOS license contemplates use by commercial enterprises on Apple-branded computers, while Apple’s Xcode terms permit development and distribution of compliant macOS applications and libraries. The material restrictions are against redistributing Apple software, extracting it, improperly sublicensing it, or reverse-engineering Apple components.

Sources:

- [Apple macOS Software License Agreement](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf)
- [Apple Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf)

Your operating rule should therefore be:

- Alloy may **invoke** Rosetta, VideoToolbox and AudioToolbox on a user’s properly licensed Mac.
- Alloy must not bundle, extract, copy or redistribute Rosetta or Apple framework binaries.
- Do not represent Rosetta as part of Alloy or as something you license to the user.
- Rosetta should remain optional, as the brief proposes, rather than a guaranteed production dependency.
- Preserve the exact macOS, Xcode and Developer Program terms applicable to every release.

This verdict only addresses the Apple contractual-use question in item 1. It does **not** answer whether use of Apple’s media decoder gives Alloy a codec-patent licence; item 5 does not come out nearly as cleanly.

---

### 2. Shipping Metal Shader Converter output

#### Verdict: **Conditional go after one documentary check**

Apple publicly describes Metal Shader Converter as converting DXIL into a Metal library ready for use on Apple platforms, and its general Xcode terms permit distribution of compliant applications and libraries created with Apple’s tools. That strongly supports shipping the resulting `.metallib`.

The unresolved issue is the one the brief identifies: **the exact package-specific licence was not available for review**.

My rule would be:

- You may plan to ship the generated `.metallib`.
- Before the first external binary, preserve a readable copy of the exact licence displayed or supplied with the precise Metal Shader Converter version used.
- Record its hash/version and the date of acceptance in the release evidence.
- Do not redistribute the converter executable, `libmetalirconverter`, SDK files, samples or other Apple tool components unless their specific terms expressly permit it.
- If the package terms contain an output restriction that conflicts with Apple’s marketing or general Xcode agreement, the package-specific restriction should be treated as controlling until resolved.

This is a **document-retention gate**, not presently a sign that the output itself is forbidden.

---

### 3. GPTK user-fetch flow

#### Verdict: **Do not ship it**

Apple’s current public description treats the D3DMetal environment as an **evaluation environment** used to assess, test and port Windows games to Apple platforms. It does not supply affirmative support for making GPTK a dependency in a third-party commercial compatibility runtime.

Source:

- [Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)

The brief also reports that GPTK has a non-commercial distribution limitation and correctly calls the Whisky-style user-fetch pattern “tolerated, not blessed.”

Having the user click a button, sign in with their Apple ID and personally accept Apple’s terms does not reliably cure the problem. Alloy would still be deliberately designing and marketing a commercial workflow whose operation depends on the user obtaining software for a purpose that may not be authorized by its licence.

**Operating decision:**

- Keep GPTK/D3DMetal strictly in the internal evaluation lab.
- Do not ship an installer, fetch script, setup wizard, plug-in or documentation designed to assemble GPTK into the production runtime.
- Do not market “bring your own GPTK.”
- Reopen the issue only if Apple publishes terms expressly authorizing this commercial third-party flow or gives written authorization.

This removes the legal ambiguity and also preserves the signed, self-contained runtime thesis.

---

### 4. LGPL compliance for the signed, immutable runtime

#### Verdict: **Hard no-go until the mechanism is implemented and tested**

Your proposed approach—published source, diffs and dynamic boundaries—is directionally correct, but it is not enough merely to point to the CrossOver model.

LGPL 2.1 §6 requires a distribution structure that gives the recipient a genuine ability to modify the LGPL library and use the resulting modified version with the application. Depending on the linking model, that means either relinkable materials or a suitable shared-library mechanism, together with permission for modification and reverse engineering needed to debug those modifications. Noncompliance risks terminating the licence on which distribution depends.

Sources:

- [GNU LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.en.html)
- [GNU LGPL overview](https://www.gnu.org/licenses/lgpl)

**Signing, notarization and content addressing are not automatically incompatible with the LGPL.** The official release can remain immutable. The problem arises if Alloy’s architecture makes a user-modified build practically unusable—for example, because library validation, hash checks, launcher policy or signature requirements reject every substituted library.

#### Minimum release design

1. **Maintain a real shared-library boundary.** Wine, DXMT and applicable GStreamer components should remain separable and interface-compatible wherever technically possible.

2. **Publish exact corresponding source for each release.** Include the precise fork, patches, configuration, build scripts, interface/header material, dependency versions and reproducible instructions corresponding to the shipped binary—not merely a link to upstream repositories.

3. **Provide a tested user-build path.** A recipient must be able to build a modified LGPL component, produce an unsigned or ad-hoc-signed Alloy runtime, and actually run that build on their own Mac. The fact that it is not your official notarized build is acceptable as a risk-management design; the path nevertheless has to work.

4. **Prevent the launcher from defeating substitution.** Content-addressed identity may distinguish an “official” runtime from a “modified” runtime, but it should not cause every user-built version to be categorically refused. A separate developer/custom-runtime launch mode is a sensible mechanism.

5. **Fix the EULA.** It must expressly preserve all LGPL rights and must not prohibit modification or reverse engineering undertaken to debug modifications to the LGPL components.

6. **Ship notices and licence texts.** Identify every covered component, version, copyright holder, modification and applicable licence, and give a durable source location.

7. **Continuously test compliance.** CI should build the published source package, substitute a deliberately modified test library, sign the resulting local runtime as documented, and verify that it launches.

8. **Audit GStreamer by actual plug-in.** GStreamer’s core licensing does not establish that every plug-in or library pulled into the bundle has identical terms; some plug-ins bring different licence or patent considerations.

Source:

- [GStreamer licensing FAQ](https://gstreamer.freedesktop.org/documentation/frequently-asked-questions/licensing.html)

Also record whether you elect LGPL 2.1 or a later version for every “2.1-or-later” component. Do not casually declare LGPLv3 without reviewing its additional requirements.

Until this entire path exists and has passed a clean-machine test, **no external binary**. This is the most concrete infringement risk in the brief.

One additional gap: the product description also names FEX and MoltenVK, but item 4 addresses only Wine, DXMT and GStreamer. Their exact redistribution, notice and source obligations must be included in the complete SBOM even though this brief does not provide enough information to clear them.

---

### 5. Codec decoding through Apple frameworks

#### Verdict: **The brief’s preliminary “clean” position is too optimistic**

This is the most important correction.

The current macOS licence contains an AVC/H.264 notice saying that commercial use may require additional licensing and that Apple’s supplied AVC functionality is licensed for personal and non-commercial consumer uses, with other uses potentially requiring a separate patent licence. In other words, **calling VideoToolbox does not itself give you a reliable blanket representation that all commercial patent rights are covered.**

Source:

- [Apple macOS Software License Agreement](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf)

Via LA’s AVC materials indicate that software media players and game-related devices can fall within the licensing programme. Even where the first tranche of units may carry no royalty, the programme warns that a licence may still be required. Access Advance similarly maintains HEVC licensing structures that can apply to products or software incorporating HEVC functionality.

Source:

- [Via LA AVC/H.264 licensing programme](https://www.via-la.com/licensing-programs/avc-h-264/)

Your architecture gives you a **good factual argument**: Alloy distributes no codec implementation, no encoded content and no streaming service; it only passes media to the operating system. But the sources presently available do not support the stronger conclusion that Apple has discharged every obligation on your behalf.

#### Practical decision

Before external distribution:

- Perform an SBOM and binary scan proving that the runtime contains no FFmpeg/libav codec implementation, no fallback decoder and no GStreamer plug-in that implements the relevant patented codecs.
- Confirm that failure of VideoToolbox does not silently fall back to a bundled software decoder.
- Send each relevant licensing administrator a written architectural question:

> Alloy distributes no encoder, decoder implementation or encoded content. It passes game-provided bitstreams to the operating system’s VideoToolbox/AudioToolbox frameworks on the user’s licensed Mac. Does the publisher of this application require a licence from your programme?

- Preserve the replies in the release record.
- Until you receive a sufficiently clear written answer, disable H.264/HEVC and other unconfirmed patented-codec paths in the external build, or retain item 5 as a release blocker.

A disclaimer in your EULA does not grant patent rights. The brief’s proposed “identify exposure and disclaim it” is therefore not a sufficient green light.

---

### 6. Steam Subscriber Agreement automation

#### Verdict: **Narrow integration only**

The current Steam Subscriber Agreement’s automation provision broadly prohibits scripts, bots, macros and other non-human-controlled systems from interacting with Steam Content and Services. Valve’s publication of SteamCMD documentation does not amount to blanket authorization for any third-party consumer product to automate users’ accounts or downloads.

Source:

- [Steam Subscriber Agreement](https://store.steampowered.com/subscriber_agreement/Steam)

I would divide the planned functions this way:

#### Acceptable or relatively low risk

- Read local, unencrypted `appmanifest_*.acf` files without modifying them.
- Detect locally installed game paths.
- Let the user manually launch the official Steam client.
- Let the user perform login, installation, updates and account interactions in Steam’s own UI.
- Launch an already installed local executable after a user action, subject to anti-cheat and publisher restrictions.

#### Do not ship without Valve’s written permission

- Automatically log in to Steam.
- Store or relay Steam credentials.
- Drive the Steam client through simulated input or process control.
- Run SteamCMD in the background to install, update or manage consumer games.
- Automate purchases, account creation, reviews, achievements, playtime, trading, rewards or other account activity.
- Interfere with Steam DRM, anti-cheat or client security mechanisms.

The brief correctly identifies credential interception as something Alloy avoids, but lack of credential interception does not resolve the separate automation language.

For version 1, make Steam interaction **user-driven and client-native**. Treat the local manifests as read-only discovery data and remove automated SteamCMD orchestration.

---

### 7. Visual Studio Community and redistributables

#### Verdict: **Go on the stated facts**

Microsoft’s current terms permit an individual developer to use Visual Studio Community to create free or paid applications. A non-enterprise organization may generally have up to five Community users. An “enterprise” is defined using **more than 250 PCs or more than US$1 million in annual revenue**—not “250 seats.”

Source:

- [Visual Studio Community licence overview](https://visualstudio.microsoft.com/vs/community/)

Therefore, a solo, pre-revenue founder is within the stated eligibility conditions.

For redistributables, only distribute the unmodified files authorized by Microsoft’s applicable Distributable List. Visual C++ runtime redistributables are commonly included, but debug/non-redistributable files are expressly outside that permission.

Source:

- [Visual Studio 2022 redistribution guidance](https://learn.microsoft.com/en-gb/visualstudio/releases/2022/redistribution)

Correct the brief to record these compliance triggers:

- a sixth Community user in a qualifying non-enterprise organization;
- more than 250 PCs within the organization; or
- more than US$1 million in annual revenue.

Recheck at fundraising, acquisition, substantial organizational growth and annually thereafter. Preserve the Visual Studio licence and Distributable List corresponding to the exact toolchain release used.

---

### 8. Proprietary Metal12 clean-room protocol

#### Verdict: **Proceed internally, but regard the protocol as evidence—not a safe harbour**

The legal foundations are real: copyright does not protect ideas, systems or methods of operation, and U.S. interoperability decisions such as *Sega v. Accolade* and *Sony v. Connectix* recognize that limited reverse engineering can be lawful where necessary to understand unprotected interfaces and the final product is independently created. Trade-secret law also distinguishes improper acquisition from lawful independent derivation or reverse engineering.

Source:

- [17 U.S.C. § 102](https://uscode.house.gov/view.xhtml?edition=prelim&num=0&req=granuleid%3AUSC-prelim-title17-section102)

But none of that creates an automatic “clean-room defence.” Your evidence must support the factual proposition that Metal12 was independently implemented from permitted information rather than copied from excluded code.

The solo-founder discipline described in the brief is defensible in principle, but I cannot certify the existing ADR or provenance record because those linked materials were not supplied here.

#### Harden it immediately

- Hash and timestamp the approved-source list and exclusion list.
- Make the provenance log append-only and externally timestamped.
- For every material feature, preserve the chain: specification requirement → design note → original implementation → test.
- Keep names, comments, data layouts and architecture traceable to an approved specification or original design decision.
- Preserve signed commits, build outputs and release snapshots.
- Record every AI tool used for Metal12, including prompts, attachments, retrieval sources and outputs.
- Verify that no AI retrieval index, coding assistant, local model corpus or search tool contains the excluded repositories.
- Never ask an assistant to compare your implementation directly against excluded source in a way that exposes the source to the developer.
- Similarity testing may be run by an isolated system that returns locations, hashes and numerical similarity indicators without displaying excluded code.
- Require future contributors to certify their source exposure and compliance with the exclusions.
- Record any historical exposure candidly. Do not describe the project as clean-room if the founder previously studied the excluded implementation.

This process addresses copyright-derivation and trade-secret evidence. It does **not** eliminate patent risk, contract restrictions on materials you obtained, or liability for actual copying.

If the isolation discipline becomes impossible to maintain, the rational fallback is to open-source the affected Metal12 implementation under compatible terms rather than rely on an evidentiary story that is not true.

---

### 9. Trademark clearance for “Alloy”

#### Verdict: **Rename now**

The USPTO evaluates likely confusion based primarily on similarity between marks and the relationship between the relevant goods and services; sharing or differing Nice classes does not by itself decide the issue. A meaningful search also extends beyond federal records to common-law and internet uses.

Source:

- [USPTO federal trademark searching guidance](https://www.uspto.gov/trademarks/search/federal-trademark-searching)

Current records show exact **ALLOY** registrations already covering software and software-as-a-service fields. One active registration associated with Alloy Software claims software use dating back to 2002, and another exact ALLOY software registration also remains in force.

Source:

- [Example ALLOY trademark record](https://trademarks.justia.com/883/65/alloy-88365982.html)

That does not establish that your planned use necessarily infringes—the precise customers, channels, functions and commercial impression would still matter. But for a solo founder, the practical answer is clear:

- the mark is an ordinary dictionary word;
- exact software uses already exist;
- registration may be narrowed, opposed or refused;
- even a defensible coexistence position can produce expensive correspondence or litigation;
- there is little reason to accumulate more goodwill under a risky name this early.

The existing GitHub repository does not give you priority over earlier users. It may provide evidence of your own date of use, but it does not cure the conflict and may not constitute qualifying trademark use for every planned good or service.

**Action:**

1. Rename the repository and product before distributing a binary.
2. Preserve a neutral redirect or changelog entry such as “formerly internal codename Alloy.”
3. Prefer a coined or highly distinctive name.
4. Search exact spelling, phonetic equivalents, translations, software-company uses, app stores, domains and federal/state records before public adoption.
5. Do not purchase a large domain portfolio, commission branding or file an application until the replacement survives that search.

The brief’s “clear / narrow / conflict” inquiry is procedurally sensible, but my founder verdict is stronger: **the expected value of preserving “Alloy” is lower than the cost and uncertainty of trying to clear it.**

---

### Recommended release sequence

1. **Rename the product and repository.**
2. **Permanently remove GPTK user-fetch from the release configuration.**
3. **Limit Steam support to read-only local discovery and user-operated official-client actions.**
4. **Create the full SBOM and remove all unapproved codec implementations and GStreamer plug-ins.**
5. **Build and test the LGPL modified-runtime path on a clean Mac.**
6. **Publish the corresponding-source bundle, notices and EULA carve-outs.**
7. **Either obtain written codec guidance or ship the first beta with the affected media paths disabled.**
8. **Archive the Apple, Microsoft and third-party licence versions corresponding to the build.**
9. **Continue the Metal12 protocol indefinitely; item 8 never becomes “finished.”**

After those controls are satisfied, a limited external beta becomes a reasonable risk decision **on these nine questions only**. This review does not clear privacy/data protection, consumer terms and refunds, export controls and sanctions, game-publisher agreements, anti-cheat restrictions, tax, accessibility, security representations, or non-U.S. law.

### Bottom line

Internal Alloy development may continue. External distribution waits on the rename, a proven LGPL compliance path and a defensible codec posture. GPTK and automated Steam interaction stay out. Items 1, 2 and 7 are manageable documentary conditions; item 8 remains a permanent engineering discipline.
