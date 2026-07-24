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
| ARM64 host launches x64 Windows tests through bootstrap and production-candidate paths | In progress | [CPU-001 result 04](CPU-001/results/2026-07-24-04-fex-first-execution-and-shear-defect.md): real FEX executes the smoke corpus + expanded corpus ([result 08](CPU-001/results/2026-07-24-08-corpus-expansion-findings.md): x87/FP, TLS, 400-thread churn, exact contended atomics, deep SEH) and a full LLVM-based compiler (dxc.exe) exit-0 | Founder FEX/EC list — exception-dispatch family RESOLVED ([result 10](CPU-001/results/2026-07-24-10-exception-dispatch-family-resolved.md): SEH corpus build artifact + JITGuardPage null-claim fix + backstop hardening; caught hardware AVs and rip-continue green on main+worker threads; residual = multi-worker-thread dispatch defect, item #24 - RECHARACTERIZED [result 11](CPU-001/results/2026-07-24-11-multi-worker-dispatch-defect-characterized.md): 2nd+ worker thread that catches a hardware fault wedges even sequentially (realistic, not synthetic); wine-side amplifier guarded so it terminates cleanly not hangs [`c5785db`]; FEX-side root open); MXCSR/FMA (pre-LAB-001); guard granularity FIXED + validated ([result 09](CPU-001/results/2026-07-24-09-guard-granularity-fixed-and-attribution-corrected.md)); census on real titles; game-scale execution |
| Wine ARM64EC/WoW64 architecture proof | In progress | WINE-001 gates 1–4 Wine side; deterministic pre-import launcher/game/default policy proof; real FEX mixed process runs (CPU-001 result 04) | Shear-enforcement decision (founder, with FEX guard fix); first rebase drill done — [result 09](WINE-001/results/2026-07-24-09-first-rebase-drill.md): 16 commits onto b41409d, zero conflicts, 2 s; full-drill trigger defined |
| D3D11 game scene through a Metal-native provider | Synthetic scope complete — title scope blocked on STORE-001 | [GFX-001 result 05](GFX-001/results/2026-07-24-05-measured-scene-and-coldboot-fix.md): measured scene green — 202 draws + 202 cbuffer maps/frame at 720p, p50 ~2 ms (233–329 fps mean), memory bounded, depth/blend/samplers proven, launcher-split child renders, cold-boot crash root-caused + fixed; draw path in [result 04](GFX-001/results/2026-07-24-04-triangle-texture-green.md), first light in [result 03](GFX-001/results/2026-07-24-03-first-light-green.md) | Real candidate titles (needs STORE-001 entitled installs): cold/warm scene automation, shader stalls, visual reference, long-session memory |
| D3D12 lab/reference scene and Metal12 micro-prototypes | M12-001..004 all green at prototype scope | [M12-001 result 01](M12-001/results/2026-07-24-01-virtual-heap-prototype.md): descriptor heap on Metal 3 argument buffers — 1.34M probes 0 mismatches, bounded ring; [M12-002 result 01](M12-002/results/2026-07-24-01-barrier-tracker-prototype.md): state tracker — 6.18M hazard pairs 0 uncovered at 90% sync elimination, GPU fence/event chains clean, hardware queue-overlap quantified; [M12-003 result 01](M12-003/results/2026-07-24-01-dxil-shader-path.md): DXIL→MSL pipeline — 5-shader corpus GPU-exact vs CPU reference, named-diagnostic rejection proven, dxc.exe itself runs under the Alloy stack; [M12-004 result 01](M12-004/results/2026-07-24-01-residency-model.md): residency — aliasing lifetime proven physical, checksummed eviction 0 mismatches, churn delta 0, budget shown advisory (self-policing required) | GPTK reference scene (founder: non-commercial GPTK install); real-trace replays Phase 1 |
| Per-process launcher/game backend split | Complete at Phase-0 prototype scope | [WINE-001 gate-4 result](WINE-001/results/2026-07-24-08-policy-hook-and-rebase-readiness.md): same imported DLL routes to launcher/DXMT, game/Metal12, and restricted default before imports | SessionAgent productionization is Phase 1+ |
| Content-addressed runtime and atomic reference prototype | Complete | [ROLLBACK-001 result](ROLLBACK-001/results/2026-07-24-01-transactional-generation-lifecycle.md) | Phase-1 productionization is out of this gate |
| First storefront install/fingerprint proof | Complete at Phase-0 scope | [STORE-001 result 01](STORE-001/results/2026-07-24-01-first-fingerprint.md): entitled Sir Brante build 24280929 fingerprinted (1,422 files, per-file + aggregate SHA-256, depot manifest ids) and rerun EXACT MATCH both unperturbed and after Steam client restart + integrity verification | Lane B (client under runtime) is Phase 1 |
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
| One exact game build is fingerprinted and reproduced in lab | Half complete | Fingerprint + exact rerun done (STORE-001 result 01); LAB-001 Windows-side reproduction remains (founder hardware) |
| Leadership accepts lab-only bootstrap D3D12 and Metal12 strategic weight | Complete | [D-021](../docs/docs/14_DECISION_LOG.md) accepted 24 July 2026; audit §3.1 signed |
| Metal12 descriptor/barrier/shader spikes show a credible path | Complete at prototype scope | M12-001..004 measured prototypes green (results 01 in each spike dir); remaining depth (trace replay, texture classes, wave ops, multi-tier hardware) is Phase-1 scope |
| Remaining existential risks have owners and deadlines | In progress | Owners exist in risk register; evidence-bound deadlines/dispositions remain missing |

## Critical sequence

1. CPU-001 Darwin host/runtime work and WINE-001 policy/rebase proof.
2. GFX-001 D3D11 scenes and M12-001/002/003/004 micro-prototypes.
3. STORE-001 install/fingerprint and LAB-001 deterministic reproduction.
4. Qualified legal review and explicit bootstrap/Metal12 leadership decision.
5. Final requirement-by-requirement Phase-0 completion audit and go/narrow/pivot decision.
