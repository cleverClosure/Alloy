# Alloy Phase-0 evidence status

**Author:** Timur Isaev
**As of:** 24 July 2026
**Authority:** Evidence index for
[`docs/docs/11_ROADMAP_TEAM_AND_DELIVERY.md` §4](../docs/docs/11_ROADMAP_TEAM_AND_DELIVERY.md)

This index does not replace the roadmap. A row is complete only when linked executable,
measurement, review, or decision evidence proves the roadmap wording at its full scope.

## Deliverables

| Deliverable | State | Current evidence | Missing proof |
| --- | --- | --- | --- |
| ARM64 host launches x64 Windows tests through bootstrap and production-candidate paths | In progress | [CPU-001 result 04](CPU-001/results/2026-07-24-04-fex-first-execution-and-shear-defect.md): real FEX (darwin-teb build) executes the ISA/exception/atomics smoke corpus exit-0 under EC Wine | Shear disposition per [result 05](CPU-001/results/2026-07-24-05-shear-cost-and-census.md) (stack-barrier alignment, census on real titles), full FEX corpus, game-scale execution |
| Wine ARM64EC/WoW64 architecture proof | In progress | WINE-001 gates 1–4 Wine side; deterministic pre-import launcher/game/default policy proof; real FEX mixed process runs (CPU-001 result 04) | Shear-enforcement decision; rebase drill awaits a newer official Wine master |
| D3D11 game scene through a Metal-native provider | Missing | No GFX-001 spike directory | Measured scenes and provider integration |
| D3D12 lab/reference scene and Metal12 micro-prototypes | Missing | Legal scope and clean-room protocol only | Reference scene plus descriptor, barrier, shader, and memory prototypes |
| Per-process launcher/game backend split | Complete at Phase-0 prototype scope | [WINE-001 gate-4 result](WINE-001/results/2026-07-24-08-policy-hook-and-rebase-readiness.md): same imported DLL routes to launcher/DXMT, game/Metal12, and restricted default before imports | SessionAgent productionization is Phase 1+ |
| Content-addressed runtime and atomic reference prototype | Complete | [ROLLBACK-001 result](ROLLBACK-001/results/2026-07-24-01-transactional-generation-lifecycle.md) | Phase-1 productionization is out of this gate |
| First storefront install/fingerprint proof | In progress | STORE-001 selects Steam and defines identity inputs | Entitled install, exact build fingerprint, rerun evidence |
| Save separation proof | Complete at Phase-0 prototype scope | ROLLBACK-001 preserves a byte-identical external save across all fault cases | Production save discovery/snapshot qualification is Phase 1+ |
| Windows/Mac deterministic test-runner proof | Missing | LAB-001 definition only | Same exact build/scenario, variance, seeded regression, cost |
| Legal component/distribution memo | In progress | LEGAL-001 preliminary findings | Nine-item qualified-counsel checklist |
| Game shortlist and scenario feasibility | In progress | CATALOG-001 portfolio decision D-020 | GFX-001/LAB-001 scenario feasibility |
| Threat-model draft | Complete as a draft | `docs/docs/09_SECURITY_PRIVACY_THREAT_MODEL.md` | Formal approval remains a later release gate |

## Exit criteria

| Exit criterion | State | Evidence needed to close |
| --- | --- | --- |
| No known fundamental macOS JIT/entitlement blocker | In progress | CPU-001 result 04 shows FEX code-cache execution with working exceptions at smoke scope; remaining: full corpus and an accepted shear-enforcement disposition |
| CPU path runs representative x64 code correctly with acceptable initial performance | Open | ISA/ABI corpus (smoke subset green in result 04), stable exceptions/unwind, deterministic game scene, measured CPU gap |
| D3D11 renders at least two representative games/scenes | Open | GFX-001 correctness, frame pacing, memory, and scene evidence |
| Per-process policy selects different graphics providers early enough | Complete | WINE-001: exact-image launcher/game plus unknown-child default select three physical provider DLLs before imports |
| Transactional runtime survives injected termination | Complete | ROLLBACK-001: 18 action/journal death points plus failed-health rollback |
| One exact game build is fingerprinted and reproduced in lab | Open | STORE-001 + LAB-001 entitled build and deterministic Mac/Windows evidence |
| Leadership accepts lab-only bootstrap D3D12 and Metal12 strategic weight | Open | Explicit decision record approving the residual schedule/runway consequence |
| Metal12 descriptor/barrier/shader spikes show a credible path | Open | M12-001/002/003 measured prototypes; M12-004 remains required by the spike schedule |
| Remaining existential risks have owners and deadlines | In progress | Owners exist in risk register; evidence-bound deadlines/dispositions remain missing |

## Critical sequence

1. CPU-001 Darwin host/runtime work and WINE-001 policy/rebase proof.
2. GFX-001 D3D11 scenes and M12-001/002/003/004 micro-prototypes.
3. STORE-001 install/fingerprint and LAB-001 deterministic reproduction.
4. Qualified legal review and explicit bootstrap/Metal12 leadership decision.
5. Final requirement-by-requirement Phase-0 completion audit and go/narrow/pivot decision.
