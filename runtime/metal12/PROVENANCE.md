# Alloy Metal12 provenance log (append-only)

**Author:** Timur Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)

Excluded sources named by ADR-0012 are not implementation inputs and must
never be read, searched, fetched, quoted, or supplied to a coding tool. Entries
are appended and never rewritten.

## Entries

- **2026-07-26 — runtime promotion and Phase-1 gates started.**
  - Approved implementation inputs were Alloy's own M12-001 through M12-006
    prototypes, results, and provenance logs; the M12-005 first-party reference
    workload and rendered answer key; the repository's `runtime/content-store`
    production-promotion layout; the public API behavior already derived from
    Microsoft DirectX specifications and Apple Metal documentation in those
    prior logs; and original experimentation.
  - The implementation used the Codex coding-agent environment and its
    repository, shell, patch, browser-control, and parallel-agent tools. The
    initiating prompt was GitHub issue #84 as supplied by the Alloy board,
    together with the repository and authoring rules. Retrieval was limited to
    that issue and explicit first-party paths listed above. Browser discovery
    enumerated existing tab titles only and supplied no design material. No
    internet search or external code retrieval informed the implementation.
  - Agent outputs comprised read-only repository and architecture
    reconnaissance, promoted proof sources, the original command/trace/runtime
    implementation, shader-corpus work, proof execution, and result
    documentation. Every output is reviewed and tested against first-party
    workloads before it becomes evidence.
  - The ignored `third_party/src/` tree was excluded by repository search
    rules during initial task discovery. After the issue's binding provenance
    instructions were read, every inspection was restricted to explicit
    approved first-party paths.

- **2026-07-26 — Gate-1 shared-model convergence and verification.**
  - Implementation inputs remained limited to first-party Alloy sources:
    M12-001 through M12-006 prototypes and results, the M12-005 workload and
    rendered answer key, ADR-0012, the existing runtime, issue #84, and the
    repository's tests and authoring rules.
  - Codex parallel agents handled bounded architecture review, model
    extraction, runtime integration, validation, and documentation tasks.
    Their outputs were reconciled in the shared worktree and accepted only
    after first-party build and regression checks.
  - The descriptor, barrier, and residency proofs and the public command path
    now share the private implementations under `Sources/Models/`. The public
    lowering operation stages the canonical DXIL-to-MSL payload embedded in
    the archive, verifies its build-time SHA-256, bounds container, resource,
    and operation counts plus child lifetime, and prevents non-standard
    descriptor inheritance. Descriptor tables are consumed through GPU-visible
    descriptor pages, and barrier-plan producer/consumer edges drive
    `MTLFence` updates and waits that are checked against the emitted edge
    matrix.
  - The converged reference build rejected 6/6 public-command divergences,
    cleaned 2/2 incomplete captures, rejected 17/17 trace mutations, reproduced
    byte-identical captures, and replayed 10/10 fresh runtimes at digest
    `44709706809f28e9`. It emitted 1/1 required fence edge offscreen and 121/121
    with presentation, with zero unmet edges.
  - Neither linked residency mode was executed. The non-pressure mode can
    still peak around 820 MiB and cannot satisfy the pressure threshold; the
    full mode crosses Metal's advisory budget and may allocate up to one GiB
    beyond it. The full execution remains required to make Gate 1 green.
  - No excluded implementation source was inspected, searched, fetched,
    quoted, or supplied to an agent. In particular, vkd3d, vkd3d-proton, DXMT
    `src/d3d12/`, and copyleft D3D12 implementations were not inputs.
