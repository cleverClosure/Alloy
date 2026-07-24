# ADR-0012: Metal12 Provenance Protocol (Proprietary Implementation, Discipline-Model Clean Room)

**Status:** Accepted
**Date:** 23 July 2026
**Author:** Tim Isaev
**Decision owners:** CEO/CTO (founder), Legal (pending counsel review)
**Related requirements:** RUN-008, SEC-007, SEC-010
**Related research:** [SPIKE-LEGAL-001 preliminary findings](../research/SPIKE-LEGAL-001-preliminary-findings.md) §6

## Context

Metal12 is the strategic proprietary D3D12→Metal implementation (ADR-0006). Three open-source D3D12 implementations exist under LGPL-2.1-or-later: **vkd3d**, **vkd3d-proton**, and — discovered during SPIKE-LEGAL-001 — **DXMT's own `src/d3d12/` subtree**. Code derived from any of them cannot remain proprietary. Institutional clean-room process uses two teams (readers write a specification; implementers never see the copyleft source). A solo founder cannot staff two teams, and contamination is irreversible for the person contaminated. Meanwhile DXMT's D3D11 code must be read and maintained routinely as the shipping D3D11 provider — the boundary must therefore be drawn inside DXMT, not around it.

## Decision

Metal12 remains proprietary. Until the team can staff a formal two-team clean room, the project operates a **discipline-model provenance protocol**:

1. **Excluded sources (never read, never search, never paste into any AI-assistant context):** vkd3d, vkd3d-proton, DXMT `src/d3d12/`, and any other copyleft D3D12 implementation that appears. Exclusion covers source, diffs, commit history, and code-level discussion threads that quote implementation code.
2. **Approved inputs:** Microsoft DirectX-Specs (CC-BY-4.0), DirectX-Headers (MIT), DXC/DirectXShaderCompiler source (NCSA), Microsoft public documentation, Apple Metal documentation and WWDC material, PIX/Metal debugger observation of Alloy's own test workloads, and original experimentation.
3. **DXMT boundary:** reading and modifying DXMT outside `src/d3d12/` (the D3D11/D3D10/DXGI provider work) is normal and expected; the exclusion is specifically its D3D12 subtree. Debugging sessions must not step "through" that subtree.
4. **Provenance log:** a dated log records nontrivial external sources consulted for Metal12 design decisions. Nontrivial Metal12 design documents cite their inputs. The log is append-only and stored with the Metal12 source.
5. **AI-assistant rule:** coding agents working on Metal12 must not be given excluded-source content, links, or instructions to consult it; generated code of unclear provenance is treated like any other unverified external code under the doc-18 §17 intake gate.
6. **Team growth rule:** any future engineer who has previously read an excluded source is walled off from writing or reviewing Metal12 implementation code; a formal two-team clean room is adopted when headcount permits, at which point this ADR is superseded.

### Evidence hardening (added 24 July 2026)

The pre-counsel assessment ([verdict](../research/SPIKE-LEGAL-001-verdict.md) item 8) confirms the legal foundations are real — idea/expression under 17 U.S.C. §102, *Sega v. Accolade* and *Sony v. Connectix* on interoperability, and trade-secret law's distinction between improper acquisition and lawful independent derivation — but is emphatic that **none of it creates an automatic clean-room defence**. This protocol is *evidence*, not a safe harbour: it must support the factual proposition that Metal12 was independently implemented from permitted information. The following are therefore part of the protocol:

- **7. Tamper-evident lists and log:** hash and timestamp the approved-input and exclusion lists; keep the provenance log append-only **and externally timestamped**, so its dates do not rest solely on our own repository.
- **8. Per-feature derivation chain:** for every material feature, preserve specification requirement → design note → original implementation → test. Keep names, comments, data layouts and architecture traceable to an approved specification or an original design decision.
- **9. Build and release evidence:** preserve signed commits, build outputs and release snapshots.
- **10. AI-tool record:** record every AI tool used for Metal12 — including prompts, attachments, retrieval sources and outputs — as part of the provenance record. Verify that no AI retrieval index, coding assistant, local model corpus or search tool contains an excluded repository.
- **11. Similarity testing without exposure:** never ask an assistant to compare our implementation directly against an excluded source in a way that exposes that source to the developer. Similarity testing runs on an isolated system that returns locations, hashes and numerical indicators without displaying excluded code.
- **12. Contributor certification:** future contributors certify their source exposure and compliance with the exclusions.
- **13. Candid exposure history:** record any historical exposure honestly. **Do not describe the project as clean-room if the founder previously studied an excluded implementation.**

This addresses copyright-derivation and trade-secret evidence only. It does **not** eliminate patent risk, contract restrictions on materials we obtained, or liability for actual copying. If the isolation discipline ever becomes impossible to maintain, the rational fallback is alternative 1 (open-source the affected implementation) rather than an evidentiary story that is not true.

## Rationale

The moat value of Metal12 (ADR-0006, strategy §7 layer 1) justifies keeping it proprietary; Microsoft's permissive publication of the D3D12 specs and headers makes an independent implementation legally well-grounded; and the discipline model is the only clean-room variant available at team size one. The residual risk — weaker evidentiary posture than an institutional clean room — is accepted and tracked (R-036).

## Consequences

### Positive

- Metal12 can proceed now without waiting for headcount.
- The proprietary-moat strategy survives at solo scale.
- Provenance evidence exists from day one if derivation is ever alleged.
- Clear rule set for AI-assisted development.

### Negative / cost

- The founder permanently forfeits three of the best reference implementations for learning D3D12 translation techniques — a real engineering-velocity cost.
- Discipline-model evidence is weaker than two-team separation; a similarity claim would be costlier to rebut.
- The DXMT-internal boundary requires ongoing care during provider maintenance.

## Alternatives considered

1. **Open-source Metal12 (LGPL), read anything:** preserves velocity and community goodwill but surrenders the technology-layer moat; the strategy's remaining moat layers (evidence graph, lab operations, trust) were judged insufficient alone at this stage. Documented as the primary fallback.
2. **Defer Metal12 until a second engineer exists:** rejected as the sole strategy — Metal12 spikes (M12-001..004) sit on the critical path and D3D11-only positioning weakens GA differentiation; deferral composes with this protocol if velocity demands it.
3. **Read first, formalize clean room later:** rejected — contamination of the sole present engineer cannot be undone.

## Validation and implementation notes

- Record the provenance log location and format before the first Metal12 spike begins.
- Add the exclusion list to CONTRIBUTING and to any AI-agent configuration used for graphics work.
- Counsel review of this protocol is item 8 of the SPIKE-LEGAL-001 counsel checklist and must precede any external Metal12 code distribution. The 24 July 2026 pre-counsel assessment reviewed the *brief's description* of this protocol but expressly **could not certify this ADR or the provenance log**, because neither was supplied to it — so item 8 remains open for counsel, and is the one item that never closes.
- A contamination event (accidental exposure) is handled as an incident: log it, scope what was seen, obtain legal review before further Metal12 work in the affected area.

## Revisit triggers

Supersede with a formal two-team clean-room ADR when team size permits. Revisit the proprietary choice itself if strategy moves to an open-core model, if a contamination event materially weakens the proprietary position, or if counsel review rejects the discipline model.
