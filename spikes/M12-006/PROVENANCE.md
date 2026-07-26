# M12-006 provenance log (append-only)

**Author:** Timur Isaev
**Protocol:** [ADR-0012](../../docs/adr/ADR-0012-metal12-provenance-and-clean-room.md)
(discipline-model clean room). Excluded sources — vkd3d, vkd3d-proton, DXMT `src/d3d12/`,
any copyleft D3D12 implementation — were not read, searched, or pasted into any
AI-assistant context for this spike. Entries are dated and never rewritten.

## Entries

- **2026-07-25 — spike start.** Log created before design work on the vertical
  slice. Inputs:
  - **The four prior M12 prototypes and their results** (M12-001 descriptor
    virtualization, M12-002 barrier tracker, M12-003 DXIL→MSL shader path,
    M12-004 residency model) — Alloy's own prior work.
  - **The M12-005 reference scene** (`d3d12_reference.c`) and its GPTK baseline
    result — Alloy's own prior work. The scene's HLSL is extracted verbatim from
    the C string literal in that file, mechanically rather than by
    transcription, so the two paths compile the same 1,333 bytes.
  - **DXC binary release** `v1.9.2602.24` (microsoft/DirectXShaderCompiler,
    NCSA — ADR-0012 approved input), used as a *tool* to produce DXIL from
    HLSL, run as the unmodified x64 `dxc.exe` under Alloy's own Wine/FEX stack.
    Now pinned in `third_party/MANIFEST.toml` and `deps.lock`. No DXC source
    read for design.
  - **DXIL operation semantics**: Microsoft public DirectX-Specs documentation
    (CC-BY-4.0) for the `dx.op` opcode numbering and signature-table meanings.
  - **Apple Metal Shading Language specification** (public) for the lowering
    target, and **Apple Metal framework documentation** (public) for the host
    API.
  - GPTK/D3DMetal remain an **answer key only** — a rendered image and a timing
    table to compare against. No excluded D3D12 translation implementation was
    read, searched, or consulted, and none is an input to any design decision
    here.
  - The stage detection, signature-table parsing, graphics-stage lowering, the
    integrated Metal path, and the comparison harness are original
    experimentation for this spike.

- **2026-07-25 — slice complete.** Additional inputs used during the work, none
  of them excluded sources:
  - `xcrun metal` / `metallib` from the installed Xcode command line tools, as
    the MSL compiler and linker.
  - Python's `zlib` for the first-party PNG reader in `compare_reference.py`;
    the decoder, the BMP reader and the comparison are original.
  - `sips` (macOS) to convert the slice's BMP output to the committed PNG. The
    conversion was verified pixel-exact by comparing the PNG back against the
    BMP through the same tool: 230,400/230,400 identical.
  - The GPTK baseline image and digest from M12-005 were read **as an answer
    key only** — a rendered result to compare against. No excluded D3D12
    translation implementation was read, searched, or consulted, and none
    informed any design decision here.

- **2026-07-26 — Phase-1 runtime promotion (#84) started.**
  - The implementation inputs are the first-party M12-001 through M12-006
    prototypes, their recorded results and provenance logs, the M12-005
    reference workload and rendered answer key, ADR-0012, and the
    `runtime/content-store` production-promotion layout.
  - The work used the Codex coding-agent environment with repository, shell,
    patch, browser-control, and parallel-agent tools. The prompt was issue #84
    from the Alloy GitHub board plus the repository and authoring rules.
    Retrieval was limited to the issue and explicit approved first-party paths;
    browser discovery supplied no implementation material and no internet
    search or external source retrieval informed the design.
  - Tool outputs include repository and architecture reconnaissance, promoted
    proof sources, original runtime/capture/replay/presentation code,
    shader-corpus extensions, proof execution, and result documentation.
    Each output is checked against first-party tests before being treated as
    evidence.
  - No excluded D3D12 translation source, diff, history, or code discussion was
    opened, searched, fetched, quoted, or supplied to any tool. The ignored
    `third_party/src/` tree was excluded by repository search rules during
    initial task discovery; subsequent inspection was restricted to explicit
    approved paths.

- **2026-07-26 — Gate-1 shared-model convergence and verification.**
  - Inputs remained first-party: Alloy's M12-001 through M12-006 prototypes,
    results, provenance, M12-005 workload and rendered answer key, ADR-0012,
    issue #84, the existing runtime, and its tests and authoring rules.
  - Codex parallel agents performed bounded model extraction, architecture and
    code review, runtime integration, verification, and documentation work in
    one shared worktree. Agent output became evidence only after reconciliation
    and first-party regression checks.
  - The promoted proofs and public runtime now call shared descriptor, barrier,
    and residency implementations under `runtime/metal12/Sources/Models/`.
    The public lowering contract stages the canonical DXIL-to-MSL payload
    embedded in the archive, validates its build-time SHA-256, and bounds
    container, resource, and operation counts, inherited descriptors, and child
    lifetime; descriptor tables are GPU-consumed through descriptor pages; and
    optimized barrier edges drive verified `MTLFence` producer and consumer
    synchronization.
  - The current reference suite rejected 6/6 public-command divergences,
    cleaned 2/2 incomplete captures, rejected 17/17 trace mutations, produced
    byte-identical captures, and replayed 10/10 fresh runtimes with digest
    `44709706809f28e9`. Fence accounting was exact at 1/1 offscreen and 121/121
    with presentation, with zero unmet edges.
  - Neither linked residency mode was executed. The non-pressure mode can
    still peak around 820 MiB and cannot satisfy the pressure threshold; the
    full mode crosses Metal's advisory budget and may allocate up to one GiB
    beyond it. The full execution remains required to make Gate 1 green.
  - No excluded source was inspected, searched, fetched, quoted, or supplied to
    an agent. This includes vkd3d, vkd3d-proton, DXMT `src/d3d12/`, and
    copyleft D3D12 implementations.

- **2026-07-26 — #84 AI-session inventory and ADR-0012 clause 10
  limitation.**
  - The prompt/context was the request to pick up and complete M12-84 from the
    Alloy board, together with the repository authoring and provenance rules.
    Parallel-agent prompts were bounded implementation, integration-review,
    evidence-design, and final-review tasks derived from #84. No file, image,
    pasted-code, or other user attachment was supplied.
  - The observable AI/tool surface was the Codex coding-agent root session and
    Codex parallel agents, with repository shell/search/build/test execution,
    patch editing, Git/GitHub CLI, and browser control used only for board or
    tab discovery. No web search or third-party code-retrieval output informed
    the implementation.
  - Observable retrieval roots were GitHub issue #84 and its project metadata;
    `origin/main`; and first-party Alloy paths comprising repository
    authoring/build rules, ADR-0012, `runtime/metal12/`,
    `runtime/content-store/`, `spikes/M12-001/` through `spikes/M12-006/`, and
    the M12-005 workload and rendered answer key. Observable outputs are the
    seven local implementation commits through `d400ca4`, their code and
    documentation, this append-only attestation and evidence-capture workflow,
    and the first-party build/proof/replay/presentation evidence recorded in
    M12-006 results 02 through 07.
  - The new evidence workflow reads only explicit approved source roots and the
    fixed Metal12 build-output tree. Its complete mode requires signed task
    commits, a signed tag, an explicit private AI-session export, and a
    caller-selected signer whose fingerprint must match the commits, tag, and
    snapshot manifest. It labels unsigned capture as incomplete and does not
    claim that local capture supplies an external timestamp or durable
    preservation.
  - Scope clarification: preceding statements that no excluded source entered
    an agent refer only to observable prompts, attachments, retrievals, tool
    calls, and returned outputs. The Codex provider did not expose an
    independently auditable inventory of its model corpus, server-side
    retrieval indexes, or coding-assistant corpus. ADR-0012 clause 10's
    environment-wide corpus/index verification therefore remains unresolved;
    no claim is made that unexposed provider or model corpora exclude
    prohibited repositories.

- **2026-07-26 — #84 evidence-integrity hardening.**
  - Independent parallel reviews of the first evidence workflow found
    concurrent build attribution, stale fixed-directory artifacts,
    compiler-cache attribution, and an observational answer-key comparison
    that did not enforce its recorded thresholds. Those reviews used only the
    current first-party Metal12 scripts, manifests, results, and configured
    runtime-tool metadata.
  - The corrected workflow serializes build, proof, and capture publication;
    freezes and rechecks native build products plus a private validated DXC
    bundle and declared Wine/FEX selected-file identity; compiles every shader
    input freshly in unique staging and a run-local Wine-prefix copy under a
    fixed empty-inherited environment; publishes accepted artifacts before the final
    manifest; and materializes reference HLSL, comparator, and answer-key bytes
    from the frozen Git commit. It does not attach to a server for the shared
    prefix. The comparator now rejects any result outside the recorded size,
    fingerprints, exact-pixel floor, or channel-delta ceiling.
  - Static-library archives use normalized libtool metadata, so independent
    runner builds from the same frozen source, canonical checkout, and selected
    native tools converge on one build-artifact and manifest identity.
  - Inspection of the ignored compiler runtime was limited to configured
    paths, file types, symlink resolution, runtime binary dependencies,
    registry bytes and selector semantics, and cryptographic hashes needed to
    identify the tools actually executed. A pre-existing server for the shared
    prefix was observed as process metadata and left running; it was neither
    inspected nor terminated. No excluded implementation source, diff, history,
    or code discussion was opened, searched, fetched, quoted, or supplied to an
    agent.
  - Capture pins issue #84 to its fixed accepted base commit, freezes the
    caller-supplied session export, and authenticates the intended snapshot
    status and exact file inventory under the selected signer. The export has
    no provider signature or independently auditable schema, so it remains
    procedural evidence rather than provider attestation.
  - Run manifests remain unsigned execution records. A later snapshot
    signature can authenticate their packaged bytes but is not an independent
    attestation that the recorded commands executed. External timestamping,
    durable private preservation, commit/tag signing, the full residency
    pressure run, and ADR-0012 clause 10's provider-corpus limitation remain
    open.
  - Terminology clarification: the configured runtime identity is not a claim
    of a complete dynamic load closure. Each run executes a private verified
    copy of the three-file DXC bundle, while the original Wine/FEX identity and
    the declared selected files in the private prefix are rechecked immediately
    around each compiler invocation. Unlisted mutable prefix files and
    undeclared dynamic runtime inputs remain outside the claim. The native
    build similarly records selected executables plus SDK identity metadata and
    explicitly does not claim a full Xcode/SDK input closure.
  - The bundled snapshot verifier is a post-authentication consistency tool,
    not a trust bootstrap. A recipient must authenticate `SHA256SUMS` and its
    signer fingerprint out of band before executing any verifier obtained from
    the snapshot.
