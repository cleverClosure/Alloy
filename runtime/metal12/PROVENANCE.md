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
