# M12-006 result 08 — PR #91 integration verification

Author: Timur Isaev

Date: 4 October 2026

Disposition: native integration checks pass; the original Phase-1 evidence is
preserved. Issues #84 and #76 remain linked to PR #91 for closure on merge.

## Integration boundary

The signed integration commit is
`87f9c89e042f897365325f61f8132a797de6a11f`. It joins original PR head
`26d54c0669d0274b8f014968fa785116f39e498b` with main at
`dd0c20cf0102e70d35908670b671b8cf8340109a`.

The only conflict was the append-only root provenance log. Both parents' entries
are preserved verbatim, followed by the new integration record. Within
`runtime/metal12/` and `spikes/M12-006/`, all original implementation, test,
script and historical-result bytes are unchanged. The only differences at the
tested merge commit are appended provenance entries. This later report adds
integration evidence; it does not amend the historical measurements.

Both the merge commit and the unchanged `m12-84-evidence` tag verify against
SSH signer `SHA256:4CXLxC8+HEpIDl4SzsNWiPRfCpatqiqm3YyOJwyGNfA`, the identity
previously authorized for this task. An independent read-only review confirmed
the preserved implementation bytes, both parent logs, and both signatures.
The signed tag still authenticates original head `26d54c0` only. The existing
private snapshot and external timestamp are not claimed to authenticate this
new integration session or its added metadata.

## Fresh native checks

Host: Apple M2 Pro, macOS 27.0 (26A428); Xcode SDK 27.0 (26A425).
The isolated checkout is `/private/tmp/alloy-84-merge`.

| Check | Observed result |
| --- | --- |
| Native library and all linked clients | Build complete from frozen clean merge commit |
| Descriptor model | 1,342,296 probes, zero mismatches |
| Descriptor negative control | Deliberate early recycle detected: 64/64 poison reads |
| Barrier model | 6,180,618 hazard pairs, zero uncovered |
| Barrier negative control | Deliberately dropped edges detected: 100/100 |
| GPU fence and cross-queue chains | Zero errors, 32 rounds each |
| Canonical lowering API | Positive case and interrupted-publication recovery pass |
| Lowering rejection controls | Interpreter override, mismatched shader hashes, oversized container, resource/operation limits and unsupported CBV range rejected |
| Repository lint | Pass |

Commands executed directly from the checkout:

```sh
runtime/metal12/run-model-proofs.sh
runtime/metal12/build/lowering_api_test
```

The model runner deliberately exits **3**, with
`status: incomplete-pressure-not-run` and `residency_mode: none`. It builds the
library and proves descriptor/barrier behavior but does not claim a new full
Gate-1 pressure run. The lowering suite exits 0. No Wine/DXC guest, shader,
presentation or residency-pressure run was performed during this integration.
The original signed generation's evidence for those gates remains historical
and is not relabeled as a result on macOS 27.

The tested runtime tree is `462e866a1a099203e96cc8c6e92e690fdab2ccdd`.
Build-manifest SHA-256: `a304337f2a0623cc5e735b882af61333bb4e180bcc700e8c668be52065b9d544`.
Model-run manifest SHA-256: `1c357810ff9eee9e7d3dec4932fe3ef8a4261617e589b0deec78f8afe26829d3`.
The model manifest includes exact invoked-binary and result-log hashes.
The subsequent documentation commit changes no implementation or test script.
Fresh hosted CI on the final PR head is required before automatic merging.

Retained local evidence:

- `runtime/metal12/build/BUILD-MANIFEST.txt` and `model-proofs/RUN-MANIFEST.txt`.
- `/private/tmp/alloy-84-models.log` and `/private/tmp/alloy-84-models.json`.
- `/private/tmp/alloy-84-lowering.log` and `/private/tmp/alloy-84-lowering.json`.
- `/private/tmp/alloy-84-lint.log`.

## Task and provenance closeout

The user authorized a 2-hour Estimate for #76. Its existing Actual remains zero
because #84 already includes that work; #84's original Estimate and recorded
13-hour Actual are preserved. The PR body retains both closing references.

Only first-party repository material, Git/GitHub metadata, existing public-key
identity and the original authorized signing key were used. No excluded
implementation source or external implementation retrieval entered either
review. Both relevant provenance logs record the prompts, observable tool
categories, inspected inputs and outputs. The existing limitation about
unexposed provider/model corpora remains explicit. No shared Wine/FEX source,
build, prefix or runtime installation was changed.
