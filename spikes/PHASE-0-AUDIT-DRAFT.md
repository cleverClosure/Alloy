# Phase-0 completion audit — DRAFT for founder go/narrow/pivot review

**Author:** Tim Isaev
**As of:** 24 July 2026
**Authority:** requirement-by-requirement audit against
[roadmap §4](../docs/docs/11_ROADMAP_TEAM_AND_DELIVERY.md); evidence index in
[PHASE-0-STATUS.md](PHASE-0-STATUS.md). This draft becomes final when the founder
executes the items in §3 and signs §4.

## 1. Deliverables (roadmap §4 wording, verbatim → verdict)

| # | Deliverable | Verdict | Evidence anchor |
| --- | --- | --- | --- |
| D1 | ARM64 host launches x64 tests through bootstrap + production paths | **Proven at corpus scope** | CPU-001 results 04–07: real FEX darwin-teb executes the smoke corpus under EC Wine; dxc.exe (full LLVM compiler) exit-0; corpus expanded with x87/FP, threading, deep-SEH guests (result 08) |
| D2 | Wine ARM64EC/WoW64 architecture proof | **Proven** | WINE-001 gates 1–4 + results 08–09; 16-commit fork rebases conflict-free onto current master |
| D3 | D3D11 game scene through Metal-native provider | **Proven at synthetic-scene scope; title scenes blocked on entitled installs under runtime** | GFX-001 results 01–05: full stack to Metal, measured 720p scene p50 ~2 ms @ 202 draws/frame, launcher-split child renders |
| D4 | D3D12 bootstrap reference scene + Metal12 micro-prototypes | **Prototypes complete (all four); GPTK scene founder-gated** | M12-001..004 results 01: descriptor heap 1.34M probes clean; barrier tracker 90% elision at 0 uncovered; DXIL→MSL corpus exact; residency bounded, budget-is-advisory |
| D5 | Per-process launcher/game backend split | **Complete at prototype scope** | WINE-001 gate 4 + GFX-001 launcher_split (D3D11 provider in spawned child) |
| D6 | Content-addressed runtime + atomic reference | **Complete** | ROLLBACK-001 result 01 |
| D7 | First storefront install/fingerprint proof | **Complete at Phase-0 scope** | STORE-001 result 01: entitled Sir Brante build 24280929, per-file+aggregate SHA-256; rerun EXACT MATCH unperturbed *and* after Steam restart + integrity verification (founder, 24 Jul) |
| D8 | Save separation proof | **Complete at prototype scope** | ROLLBACK-001 byte-identical external save across fault cases |
| D9 | Windows/Mac deterministic test-runner proof | **Open — founder-gated** | LAB-001 needs Windows lab hardware + a title; STORE-001 fingerprint JSON is the ready identity anchor; FMA/MXCSR findings (CPU-001 result 08) are pre-registered determinism risks |
| D10 | Legal memo | **Preliminary done; counsel pending** | LEGAL-001 findings; nine-item counsel checklist is the founder/external dependency |
| D11 | Game shortlist + scenario feasibility | **Shortlist decided (D-020); feasibility partially proven** | CATALOG-001; GFX-001 synthetic feasibility done; per-title scenarios need entitled installs |
| D12 | Threat-model draft | **Complete as draft** | docs/docs/09 |

## 2. Exit criteria (verbatim → verdict)

| # | Criterion | Verdict |
| --- | --- | --- |
| E1 | No known fundamental macOS JIT/entitlement blocker | **Holds.** MAP_JIT + code-cache execution + exceptions proven at corpus scope; no blocker class found. Known non-fundamental defects with founder-scoped fixes: FEX 4 KB guard granularity (result 06), MXCSR flags, FMA fusion (result 08) |
| E2 | CPU path runs representative x64 code, correct exceptions, acceptable initial perf | **Holds at single-thread scope with five named FEX/EC defects** (guard granularity; MXCSR sticky flags; FMA non-fusion; **multi-thread guest-AV exception-dispatch deadlock** — the most game-relevant one; Rip-modify continue-execution hang) plus the dispatcher-gadget x18 fault-tax telemetry — all founder-scoped, none architectural; CPU-001 result 08 |
| E3 | D3D11 renders ≥2 representative games/scenes | **Scenes: synthetic proven. Games: blocked on entitled installs under the runtime** — the one criterion that cannot close without founder title work |
| E4 | Per-process policy early enough | **Complete** |
| E5 | Transactional runtime survives injected termination | **Complete** |
| E6 | One exact build fingerprinted + reproduced in lab | **Half: fingerprint + exact rerun done; lab (Windows) reproduction awaits LAB-001 hardware** |
| E7 | Leadership accepts bootstrap D3D12 lab-only + Metal12 weight | **Complete** — D-021 signed 24 July 2026 (§3.1) |
| E8 | Metal12 spikes show credible path | **Complete at prototype scope** (M12-001..004 measured) |
| E9 | Remaining existential risks have owners + deadlines | **Draft dispositions in §3.2 — founder ratification required** |

## 3. Founder-only closure items (everything else is done or in evidence)

### 3.1 Decision record — D-021: bootstrap D3D12 scope and Metal12 weight (SIGNED)

> Accepted: GPTK/D3DMetal remains lab/reference-only (non-commercial license,
> LEGAL-001); the commercial D3D12 path is Metal12, now evidenced by four green
> micro-prototypes (M12-001..004). Accepted consequence: Metal12 carries schedule
> weight into Phases 1–2 with the ADR-0012 discipline-model clean room as its legal
> posture pending counsel item 8. Fallback remains open-sourcing Metal12 (ADR-0012
> alternative 1) if a contamination event or counsel rejection materializes.
> — **Signed: Tim Isaev, 24 July 2026 — recorded as [D-021](../docs/docs/14_DECISION_LOG.md). E7 closed.**

### 3.2 Risk-register deadline drafts (E9)

| Risk | Owner | Proposed evidence-bound deadline |
| --- | --- | --- |
| FEX guard granularity (4 KB) | Founder | before first real-title census (gate: STORE-001 title under runtime) |
| Multi-thread guest-AV dispatch deadlock | Founder | **before any real title** — games fault with live threads routinely (JIT, copy protection); repro = seh_concurrent.c + two samples |
| MXCSR flags + FMA fusion | Founder | before LAB-001 determinism runs (pre-registered divergence sources) |
| Rip-modify continue-execution hang | Founder | with the dispatch-deadlock work (same exception-dispatch area) |
| Dispatcher-gadget x18 fault tax | Founder | emit tpidrro-based TEB loads in FEX gadgets; absorb telemetry now in the fork |
| Counsel checklist (9 items) | Founder + counsel | before any external binary distribution |
| LAB-001 Windows hardware | Founder | Phase-1 week 1 |

### 3.3 Remaining founder execution list

1. FEX tree fixes (no-AI policy), exception-dispatch deadlock family first.
2. GPTK lab install + reference scene (non-commercial, lab-only).
3. Entitled title under the runtime → E3's two game scenes + real-title census.
4. Counsel engagement on the nine-item checklist.
5. Ratify §3.2 risk deadlines. *(§3.1 signed as D-021; perturbed STORE-001 rerun EXACT MATCH — both 24 Jul.)*

## 4. Go / narrow / pivot recommendation (draft)

Every architectural bet of Phase 0 now has running-code evidence: x64 executes, EC
Wine routes, D3D11 renders and paces, Metal12's four hard subproblems prototype
green, the runtime survives kills, and a real entitled build fingerprints exactly.
No fundamental blocker surfaced anywhere in the stack. The open items are execution
work (titles, counsel, one hardware purchase, founder-scoped FEX fixes), not
viability questions. **Draft recommendation: GO, with E3 title evidence as the first
Phase-1 milestone rather than a Phase-0 blocker — subject to founder sign-off.**
