# Contributing to the MGCR Documentation Baseline

## 1. Change types

- Product requirement change
- Architecture or ADR change
- Contract/schema change
- Certification/test change
- Security/privacy change
- Operational/release change
- Planning/risk clarification

## 2. Required pull-request content

Every material change includes:

- problem and reason;
- affected requirement IDs;
- affected documents/schemas;
- compatibility and migration impact;
- security/privacy impact;
- testing/evidence impact;
- operational/rollback impact;
- decision/ADR link where needed;
- owner and target milestone.

## 3. Writing rules

- Use exact, testable language.
- Distinguish current fact, product requirement, planning target, and hypothesis.
- Do not label a title or feature supported without exact scope/evidence.
- Do not hide security, anti-cheat, DRM, licensing, or platform constraints.
- Keep user-facing language separate from technical error codes.
- Preserve stable requirement/decision IDs.
- Use Mermaid for portable diagrams where possible.
- Keep examples clearly non-normative.

## 4. Requirement changes

A requirement change updates:

- `docs/02_PRD.md`;
- `docs/12_REQUIREMENTS_TRACEABILITY_MATRIX.md`;
- relevant architecture/specification;
- roadmap/risk if scope or timing changes;
- tests and release gates.

P0 deferral or waiver requires Product, Engineering, and the appropriate Security/Quality authority.

## 5. Architecture decisions

Create or supersede an ADR when the change is long-lived, cross-cutting, costly to reverse, or rejects a plausible alternative.

ADRs contain:

- context;
- decision;
- rationale;
- positive and negative consequences;
- alternatives;
- validation;
- revisit triggers.

## 6. Schema changes

- Validate against the declared JSON Schema version.
- Add positive and negative fixtures.
- Define compatibility/migration.
- Update policy compiler golden outputs.
- Update the example profile.
- Review security ceilings.
- Never add arbitrary script execution to a stable profile.

## 7. Review checklist

- Is the claim precise?
- Is it testable?
- Does it preserve save safety?
- Does it preserve Certified/Custom separation?
- Does it change host access, JIT, signing, secrets, telemetry, or anti-cheat?
- Is a rollback or migration defined?
- Are owners and release stage clear?
- Are external legal/licensing assumptions explicit?
- Does the user-facing status remain honest?

## 8. Generated artifacts

Production repositories should generate:

- Markdown link checks;
- schema validation;
- requirement/ADR index;
- table-of-contents;
- release documentation digest;
- traceability coverage report.

Generated outputs should not be edited manually.

## 9. Provenance rules (ADR-0012)

Metal12 is developed under a discipline-model clean-room protocol, not an open reference implementation:

- Excluded sources — vkd3d, vkd3d-proton, and DXMT's `src/d3d12/` subtree — are never read, searched, or pasted into any context, including AI coding assistants, while working on Metal12. DXMT's non-D3D12 code (D3D10/11/DXGI) remains normal, expected reading.
- A coding agent assisting with Metal12 must not be given excluded-source content, links, or instructions to consult it. Generated code of unclear provenance is treated as unverified external code under the `docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md` dependency intake gate.
- Nontrivial external sources consulted for a Metal12 design decision are recorded in the dated, append-only provenance log stored with the Metal12 source; nontrivial design documents cite their inputs.
- Anyone who has read an excluded source is walled off from writing or reviewing Metal12 implementation code. Accidental exposure is handled as an incident: log it, scope it, get legal review before further Metal12 work in the affected area.

See `adr/ADR-0012-metal12-provenance-and-clean-room.md` for full context and rationale.
