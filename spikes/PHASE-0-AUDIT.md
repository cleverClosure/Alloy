# Phase-0 completion audit — founder go/narrow/pivot review

**Author:** Tim Isaev
**As of:** 25 July 2026 (evidence refreshed; **SIGNED — GO**, §4)
**Authority:** requirement-by-requirement audit against
[roadmap §4](../docs/docs/11_ROADMAP_TEAM_AND_DELIVERY.md); evidence index in
[PHASE-0-STATUS.md](PHASE-0-STATUS.md). Final: the founder executed the items in
§3 and signed §4 on 25 July 2026.

> **State: SIGNED — GO, 25 July 2026.** Evidence below is current as of that date and
> every §3.3 item carries its closure status. §4 records the decision, the E3
> disposition, and the D10 disposition.
>
> The two items that gated a final audit are dispositioned rather than closed: issue
> #13 (counsel) remains open and gates the first external binary, not this decision;
> E3's remaining title evidence moves to the first Phase-1 milestone. §4 states both
> explicitly so neither is read as having been satisfied.

## 1. Deliverables (roadmap §4 wording, verbatim → verdict)

| # | Deliverable | Verdict | Evidence anchor |
| --- | --- | --- | --- |
| D1 | ARM64 host launches x64 tests through bootstrap + production paths | **Proven at corpus *and* real-title scope** | Real-title execution census (result 19, issue #12): 2,000,000 decoded instructions across 36 threads of the entitled build, 279 distinct mnemonics, ordinary integer and control-flow x86, one undispatchable decode in two million and it is not in the game image. Earlier: CPU-001 results 04–07: real FEX darwin-teb executes the smoke corpus under EC Wine; dxc.exe (full LLVM compiler) exit-0; corpus expanded with x87/FP, threading, deep-SEH guests (result 08) |
| D2 | Wine ARM64EC/WoW64 architecture proof | **Proven** | WINE-001 gates 1–4 + results 08–09; 16-commit fork rebases conflict-free onto current master |
| D3 | D3D11 game scene through Metal-native provider | **Proven at synthetic-scene scope and on one entitled title; breadth needs a second title** | The entitled build boots and renders under the runtime — Unity 2018.3, `Direct3D 11.0 [level 11.1]` through native DXMT, headless and graphical, zero livelock heartbeats (STORE-001 result 02, issues #10/#30). What remains is a *second* title, not a runtime blocker. GFX-001 results 01–05: full stack to Metal, measured 720p scene p50 ~2 ms @ 202 draws/frame, launcher-split child renders |
| D4 | D3D12 bootstrap reference scene + Metal12 micro-prototypes | **Prototypes complete (all four); GPTK scene founder-gated** | M12-001..004 results 01: descriptor heap 1.34M probes clean; barrier tracker 90% elision at 0 uncovered; DXIL→MSL corpus exact; residency bounded, budget-is-advisory |
| D5 | Per-process launcher/game backend split | **Complete at prototype scope** | WINE-001 gate 4 + GFX-001 launcher_split (D3D11 provider in spawned child) |
| D6 | Content-addressed runtime + atomic reference | **Complete** | ROLLBACK-001 result 01 |
| D7 | First storefront install/fingerprint proof | **Complete at Phase-0 scope** | STORE-001 result 01: entitled Sir Brante build 24280929, per-file+aggregate SHA-256; rerun EXACT MATCH unperturbed *and* after Steam restart + integrity verification (founder, 24 Jul) |
| D8 | Save separation proof | **Complete at prototype scope** | ROLLBACK-001 byte-identical external save across fault cases |
| D9 | Windows/Mac deterministic test-runner proof | **Open — founder-gated** | LAB-001 needs Windows lab hardware + a title; STORE-001 fingerprint JSON is the ready identity anchor; the MXCSR sticky-flag finding (result 12) is a pre-registered determinism risk — **an implementation was attempted and did not land** (issue #7): correct in shape and regression-free, but a verified experiment shows FEX's `STMXCSR` handler is not what services the guest instruction in this ARM64EC configuration, so the risk stays open and un-mitigated for LAB-001 (FMA cleared as bit-exact, result 12; CPU throughput/scaling measured, results 14–15) |
| D10 | Legal memo | **Preliminary + pre-counsel review done; qualified counsel still pending** | LEGAL-001 findings, counsel brief 0.2, and a recorded [pre-counsel assessment](../docs/research/SPIKE-LEGAL-001-verdict.md) that is explicitly *not* an attorney opinion. It moved four items — codecs escalated to a release gate, GPTK user-fetch closed as do-not-ship, VS thresholds corrected, and **the product name assessed as a conflict requiring a rename before first external binary**. Issue #13 remains open; this deliverable cannot close without counsel |
| D11 | Game shortlist + scenario feasibility | **Shortlist decided (D-020); feasibility partially proven** | CATALOG-001; GFX-001 synthetic feasibility done; per-title scenarios need entitled installs |
| D12 | Threat-model draft | **Complete as draft** | docs/docs/09 |

## 2. Exit criteria (verbatim → verdict)

| # | Criterion | Verdict |
| --- | --- | --- |
| E1 | No known fundamental macOS JIT/entitlement blocker | **Holds.** MAP_JIT + code-cache execution + exceptions proven at corpus scope; no blocker class found. Known non-fundamental defects: FEX 4 KB guard granularity (results 06/13) and MXCSR sticky flags (cosmetic, result 12 — implementation attempted and did not land, issue #7). FMA fusion was retired as a non-defect — FEX's FMA is bit-exact single-rounded (result 12) |
| E2 | CPU path runs representative x64 code, correct exceptions, acceptable initial perf | **Holds — proven correct and performant at synthetic/prototype scope.** Corpus is full green and bit-exact (18 tests built, results 12–17; `seh_concurrent` and `seh_multi` moved from *excluded by design* to green, and `seh_repeat` added for the repeated-AV axis); CPU throughput measured native-parity on integer to ~2.7x worst-case single-thread (result 14) and linear multi-thread scaling to 8 cores at 100% efficiency (result 15). Remaining FEX/EC defects are founder-scoped, none architectural: 4 KB guard granularity (shear, results 06/13), MXCSR sticky exception-status flags (cosmetic — no title reads them, result 12), and the **multi-thread guest-AV exception-dispatch defect** (item #24) — which **no longer reproduces**: with the spike toolchain repaired and the FEX log sink live, 63 runs across every concurrency shape, both FEX builds and logging on/off are green, and the failure signature is *positively* absent (all four workers now pack the valid guest RIP that result 11 saw from only one). The root cause was **not** identified and six candidate explanations were eliminated, so it is closed as not-reproducible-at-HEAD with regression tests retained (`seh_repeat`, 800 caught AVs per shape), not as understood — see result 16. A separate pre-existing red was charted while testing it and has since been **fixed**: guest calls through a null function pointer now reach the guest handler, 100/100 caught with `info0=8` and address 0, corpus 31/31 (issue #20, result 20). Two earlier-listed defects were **retired**: FMA is bit-exact single-rounded (result 12 — the reported non-fusion was compiler contraction, not FEX) and Rip-modify continue-execution is green (result 10) |
| E3 | D3D11 renders ≥2 representative games/scenes | **Scenes: synthetic proven. Games: one of two.** The entitled build renders under the runtime (D3); the criterion's second title requires another purchase. No longer blocked on the runtime's ability to boot titles — that is evidenced. **Dispositioned to the first Phase-1 milestone, §4** |
| E4 | Per-process policy early enough | **Complete** |
| E5 | Transactional runtime survives injected termination | **Complete** |
| E6 | One exact build fingerprinted + reproduced in lab | **Half: fingerprint + exact rerun done; lab (Windows) reproduction awaits LAB-001 hardware** |
| E7 | Leadership accepts bootstrap D3D12 lab-only + Metal12 weight | **Complete** — D-021 signed 24 July 2026 (§3.1) |
| E8 | Metal12 spikes show credible path | **Complete at prototype scope** (M12-001..004 measured) |
| E9 | Remaining existential risks have owners + deadlines | **Complete — ratified 24 July 2026** (risk register §2.1; FMA fusion and rip-modify retired at ratification) |

## 3. Founder-only closure items (everything else is done or in evidence)

### 3.1 Decision record — D-021: bootstrap D3D12 scope and Metal12 weight (SIGNED)

> Accepted: GPTK/D3DMetal remains lab/reference-only (non-commercial license,
> LEGAL-001); the commercial D3D12 path is Metal12, now evidenced by four green
> micro-prototypes (M12-001..004). Accepted consequence: Metal12 carries schedule
> weight into Phases 1–2 with the ADR-0012 discipline-model clean room as its legal
> posture pending counsel item 8. Fallback remains open-sourcing Metal12 (ADR-0012
> alternative 1) if a contamination event or counsel rejection materializes.
> — **Signed: Tim Isaev, 24 July 2026 — recorded as [D-021](../docs/docs/14_DECISION_LOG.md). E7 closed.**

### 3.2 Risk-register deadlines (E9) — RATIFIED

> Ratified: Tim Isaev, 24 July 2026 — recorded in
> [13_RISK_REGISTER.md §2.1](../docs/docs/13_RISK_REGISTER.md). Corrections applied at
> ratification: FMA fusion retired as a non-defect (result 12); rip-modify
> continue-execution retired as green (result 10). E9 closed. Open items track as
> issues #6, #7, #8, #13, #15.

| Risk | Owner | Proposed evidence-bound deadline |
| --- | --- | --- |
| FEX guard granularity (4 KB) | Founder | DONE 24 Jul (result 09): host-page-sized, validated by guard_enforce.c (4K unenforced / 16K enforced) |
| Multi-thread guest-AV dispatch deadlock | Founder | **before any real title** — games fault with live threads routinely (JIT, copy protection); repro = seh_concurrent.c + two samples |
| MXCSR flags + FMA fusion | Founder | before LAB-001 determinism runs (pre-registered divergence sources) |
| Rip-modify continue-execution hang | Founder | with the dispatch-deadlock work (same exception-dispatch area) |
| Dispatcher-gadget x18 fault tax | Founder | emit tpidrro-based TEB loads in FEX gadgets; absorb telemetry now in the fork |
| Counsel checklist (9 items) | Founder + counsel | before any external binary distribution |
| LAB-001 Windows hardware | Founder | Phase-1 week 1 |

### 3.3 Remaining founder execution list

Status refreshed 25 July 2026. The FEX-tree items were worked under a founder
authorization extending the fork's AI carve-out to specific issues; all such
commits are fork-local and listed in `third_party/src/fex/PROVENANCE-ALLOY.md`.

1. ~~FEX tree fixes, exception-dispatch deadlock family first.~~ **Substantially
   closed.** Item #24 no longer reproduces (result 16, issue #6) and the
   dispatcher-gadget fault tax was measured and found not to exist as framed
   (result 17, issue #8). Two items remain open and are *not* Phase-0 blockers:
   MXCSR sticky flags (issue #7 — attempted, verified dead end) and the newly
   charted null-function-pointer dispatch gap (issue #20).
2. ~~GPTK lab install + reference scene (non-commercial, lab-only).~~ **Done**
   (issue #9). Note the pre-counsel assessment has since closed GPTK
   *user-fetch* as do-not-ship; lab-only use is unaffected.
3. **Open.** Entitled title under the runtime → E3's two game scenes +
   real-title census (issues #10 in progress, #11, #12).
4. **Open — and now the widest item.** Counsel engagement on the nine-item
   checklist (issue #13). A pre-counsel assessment is on file and has already
   tightened what we may do today, but it is not an attorney opinion and D10
   cannot close on it. It also added release gates that are Phase-1 execution
   work: prove the LGPL modified-runtime path (#23), an SBOM/codec-clean build
   (#24), narrow Steam to read-only discovery (#25), and **rename the product
   before any external binary** (#26).
5. ~~Ratify §3.2 risk deadlines.~~ *(Done 24 Jul — risk register §2.1. §3.1 signed as D-021; perturbed STORE-001 rerun EXACT MATCH — both 24 Jul.)*

## 4. Go / narrow / pivot decision

Every architectural bet of Phase 0 has running-code evidence: x64 executes, EC
Wine routes, D3D11 renders and paces, Metal12's four hard subproblems prototype
green, the runtime survives kills, and a real entitled build fingerprints exactly
— and now boots and renders under the runtime. No fundamental blocker surfaced
anywhere in the stack. The open items are execution work (a second title,
counsel, one hardware purchase, founder-scoped FEX fixes), not viability
questions.

### What changed since the 24 July draft

The recommendation is unchanged; the evidence under it moved in five ways, three
of which strengthen it and two of which do not.

- **Strengthens it.** The defect the audit called "the most game-relevant"
  (item #24, multi-thread guest-AV dispatch) no longer reproduces, and the
  corpus now covers the repeated-AV axis it never did. E2's residual defect list
  is materially shorter.
- **Strengthens it.** The entitled title now **boots and renders under the
  runtime** — Unity 2018.3 with `Direct3D 11.0 [level 11.1]` through native
  DXMT, headless and graphical (#10, unblocked by #30). E3's remaining gap is a
  second purchase, not a runtime that cannot run games. That is a different
  class of risk from the one the 24 July draft recorded.
- **Strengthens it.** D1 is now proven at real-title scope, not just corpus
  scope: two million decoded instructions across 36 threads, 279 distinct
  mnemonics, ordinary integer and control-flow x86 (#12). The translator faces
  nothing exotic in real game code. The null-function-pointer dispatch defect
  charted during #6 is also fixed (#20).
- **Does not.** The root cause of #24 was never found — it is closed as
  not-reproducible, which is a weaker claim than fixed, and the regression tests
  are what protect it. Two CPU items also failed to land: MXCSR sticky flags
  (a verified dead end) and the x18 fault tax (a premise that measurement did
  not support at corpus scale — and which #36 now shows costs 300,763 absorbs
  per title boot, three orders of magnitude above the figure that closed it).
- **Does not.** The pre-counsel assessment did not clear D10; it narrowed what
  we may ship and added a rename to the critical path. A GO signed today is a GO
  on *viability*, not on readiness to distribute anything.

### Signature — go / narrow / pivot

```text
Decision (GO / NARROW / PIVOT): GO

E3 disposition (Phase-1 milestone / Phase-0 blocker): Phase-1 milestone

D10 disposition (gates external binary only / gates GO): gates external
                                                         binary only

Signed: Tim Isaev                           Date: 25 July 2026
```

**What this decision does and does not assert.**

- It asserts that Phase 0's question — *is this architecture viable* — is
  answered yes, on running-code evidence in every deliverable.
- It does **not** assert that anything is shippable. D10 is open. Counsel has
  not reported, the product name is assessed as requiring a rename before the
  first external binary, and codecs are escalated to a release gate. Issue #13
  gates the first external artifact and is unaffected by this signature.
- It does **not** close E3 on its literal wording. E3 asks for two representative
  games; one is evidenced. The second moves to the first Phase-1 milestone, where
  it is a purchasing and measurement task rather than a viability question.
  Issue #11 (two D3D11 title scenes) carries it.
- It does **not** treat #24 as understood. It is closed as not-reproducible with
  regression tests retained, and that distinction is preserved deliberately.

**Consequent state.** Phase 0 is complete. Issues #11, #13, #15 and #36 continue
as Phase-1 work under their existing owners; none of them blocks this decision.
