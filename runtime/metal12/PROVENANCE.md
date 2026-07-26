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
  - The source archive is extracted with its Git-materialized file modes
    preserved, then compared against the frozen materialization for exact root,
    inventory, byte, and regular-file mode equality before publication.
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

- **2026-07-26 — historical spike comparator preservation.**
  - Final acceptance review found that evidence hardening had changed the
    M12-006 prototype comparator even though the spike tree is historical
    evidence. The prototype bytes were restored to the accepted task base.
  - The fail-closed comparison implementation now lives canonically at
    `runtime/metal12/Tests/compare_reference.py`. Reference execution and
    evidence capture bind that tracked runtime file by Git path and SHA-256;
    the size, baseline and slice fingerprints, exact-pixel floor, and channel
    delta ceiling remain enforced.
  - The same review corrected a stale result statement from before compiler
    cache removal. Canonical shader evidence performs 11 fresh DXC invocations
    per evidence batch and accepts no prior-run cache reads. Each corpus shader
    now emits DXIL and disassembly together once per batch; the reference path
    likewise uses one combined invocation for each of its two stages. All
    later test iterations within a batch reuse those outputs.
  - Result 01's offscreen-speedup warning was replaced with the measured
    `CAMetalLayer` comparison required by #76 while retaining the original
    offscreen rows for cost attribution.
  - The review and correction used only issue #84 and the current first-party
    task diff. No excluded source or external implementation material was
    inspected, searched, fetched, quoted, or supplied to an agent.

- **2026-07-26 — #84 evidence-generation reconciliation.**
  - Final acceptance review found that result documents mixed exact values
    from historical gate runs with a later manifest-bound reproduction. Results
    01 through 07 now name those generations separately and bind the
    reproduction by tested commit, runtime tree, run-manifest digest, and
    unsigned staging checksum without claiming that the earlier snapshot
    covers the later documentation-only descendant.
  - The former static seven-commit inventory was stale after evidence
    hardening. Task-history inventory is now capture-bound: each snapshot's
    frozen `metadata/commit-list.txt`, pinned base, HEAD, and source archive
    enumerate the exact generation. This prose intentionally does not embed a
    commit count or terminal HEAD that its own update would invalidate.
  - The reconciliation and review used only issue #84, current first-party
    task files, and the checksum-closed private staging evidence. No excluded
    implementation source, diff, history, code discussion, or external
    implementation material was opened, searched, fetched, quoted, or supplied
    to an agent.

- **2026-07-26 — #84 authorized residency-pressure execution.**
  - The user explicitly authorized the full hardware-pressure gate on the
    measured Mac. The first-party command
    `runtime/metal12/run-model-proofs.sh --include-residency-pressure` executed
    the shared linked model at tested commit `5c463b7`.
  - The eviction cache verified 109 rematerializations with zero mismatches.
    The proof completed 20,000 churn operations, peaked at 820 MB, and
    allocated 13,184 MB against Metal's 12,124 MB advisory budget with zero
    allocation failure. Metal allocation returned from its 0.1 MB baseline to
    0.1 MB after release, and post-release process footprint measured 3.8 MB.
    The model manifest records `complete-pressure-pass` and
    `residency_mode: pressure`.
  - The run is packaged in a checksum-closed private unsigned staging
    generation with `SHA256SUMS` digest
    `2b8ef5a50a20dc3a52c8833b206d1a01cb2bfaae9b0fa262bbfde9a6752a0d6d`.
    It remains `STAGING_ONLY`; capture packaged existing artifacts and did not
    itself execute the pressure test.
  - The authorization, execution, and review introduced no external
    implementation input. No excluded source, diff, history, code discussion,
    or quoted material was opened, searched, fetched, or supplied to an agent.

- **2026-07-26 — #84 signed-history closeout reconciliation.**
  - The user approved closeout with SSH signer fingerprint
    `SHA256:4CXLxC8+HEpIDl4SzsNWiPRfCpatqiqm3YyOJwyGNfA`. The 17-commit task
    chain was rewritten one-for-one from the same pinned base so every commit
    carries that signature. Two non-gate evidence subjects were corrected to
    Gate-6 subjects; commit order, file trees, and author identity were
    preserved.
  - Historical unsigned identifiers remain historical rather than being
    upgraded in place. Equal-tree mappings include final-acceptance commit
    `94afcc2fee0742b0887f46cd356e1c54a4bb191d` to
    `f7464a205445331f335f77ef5dd4417abd2a3701`, authorized-pressure commit
    `5c463b76dd18f37c06a4ab22b11d5347514fab21` to
    `9f4f6ff6acc4c5e65dea30b94a07522b56cf5329`, and pre-signing tip
    `5955a2f9f180242dce7d09b22764c65c31538f8e` to
    `28f6710a649811f4f978dca164118c3a1187bc8b`.
  - The exact closing commit, manifests, archive, and checksum set are bound by
    the signed `m12-84-evidence` tag and private capture rather than embedded in
    this self-containing tracked entry. Timestamp and durable-storage receipts
    remain out-of-band. ADR-0012 clause 10's unexposed provider/model-corpus
    inventory remains explicitly unresolved.
  - This reconciliation used only the current first-party task and evidence
    records. No excluded implementation source, diff, history, code
    discussion, or quoted material was opened, searched, fetched, or supplied
    to an agent.
