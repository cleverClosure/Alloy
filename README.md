# Alloy

**Author:** Tim Isaev

A certified Windows-game compatibility runtime for Apple Silicon Macs: thin Wine fork,
FEX/ARM64EC CPU translation, Metal-native graphics providers, immutable content-addressed
runtime generations, and a continuous differential certification lab.

Product and architecture documentation lives in [`docs/`](docs/README.md) — start with the
[document map](docs/docs/00_DOCUMENT_MAP.md). Decisions are recorded in
[`docs/adr/`](docs/adr/) and the [decision log](docs/docs/14_DECISION_LOG.md).

## Repository layout

| Path | Contents |
| --- | --- |
| `docs/` | The versioned product documentation package (revision-controlled; one commit per CHANGELOG revision) |
| `spikes/` | Phase-0 technical spikes — one directory per spike ID from [doc 16](docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md), each with a `SPIKE.md` plan and committed `results/` |
| `third_party/` | Pinned upstream dependencies: `MANIFEST.toml` (roles, licenses, upstream URLs) and `deps.lock` (exact commits) are committed; `src/` checkouts are not |
| `tools/` | Bootstrap and dependency scripts; downloaded toolchains land in `tools/toolchains/` (not committed) |
| `src/` | Product source (created as components begin; nothing ships from spikes without meeting production standards — doc 16 §8) |
| `PROVENANCE.log` | Append-only provenance record per [ADR-0012](docs/adr/ADR-0012-metal12-provenance-and-clean-room.md) |

## Getting started

```sh
tools/bootstrap.sh     # verify/install host build deps + lint stack, install git hooks
tools/fetch-deps.sh    # clone pinned upstreams into third_party/src/ and write deps.lock
```

## Code style

First-party code is linted on every commit (`tools/hooks/pre-commit` →
`tools/lint.sh`; `tools/lint.sh --fix` repairs formatting). Rules, scope
boundaries (third-party trees keep their upstream styles), and the workflow
are in [`CODE_STYLE.md`](CODE_STYLE.md).

## Provenance rules (binding)

Per ADR-0012, the following are **excluded sources** for anyone working on Metal12 or D3D12
translation: vkd3d, vkd3d-proton, and DXMT `src/d3d12/`. Do not read them; do not paste them
into AI-assistant context. Approved inputs: DirectX-Specs (CC-BY-4.0), DirectX-Headers (MIT),
DXC, Apple Metal documentation. Full rules: [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) §9.
DXMT is therefore fetched only when D3D11 provider work starts, with the exclusion guard
described in `third_party/MANIFEST.toml`.
