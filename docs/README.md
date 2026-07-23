# Mac Gaming Compatibility Runtime — Product Documentation

This repository-style package defines a product and engineering baseline for an Apple-silicon-only runtime that runs **supported Windows games on macOS as certified, reproducible per-game environments**.

The working name **MGCR** is descriptive and not a final brand.

## Start here

- [Documentation map](docs/00_DOCUMENT_MAP.md)
- [Product strategy](docs/01_PRODUCT_STRATEGY.md)
- [Product Requirements Document](docs/02_PRD.md)
- [Full technical architecture](docs/04_TECHNICAL_ARCHITECTURE.md)
- [Roadmap, team, and delivery plan](docs/11_ROADMAP_TEAM_AND_DELIVERY.md)
- [Risk register](docs/13_RISK_REGISTER.md)
- [Open questions and technical spikes](docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md)
- [Legal, open-source, and distribution plan](docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md)
- [MVP epics and initial backlog](docs/19_MVP_EPICS_AND_BACKLOG.md)

## Core thesis

MGCR does not expose a mutable Wine bottle as the product. Its unit of support is:

```text
exact game and launcher build
+ exact Mac capability class
+ immutable runtime generation
+ signed per-process compatibility policy
+ current test and certification evidence
+ safe rollback generation
```

The strategic differentiation is the combination of:

1. per-process compatibility routing;
2. immutable per-game runtime generations;
3. an owned Direct3D 12-to-Metal path;
4. Apple-specific CPU, memory, synchronization, presentation, input, audio, and media engineering;
5. a continuous Mac/Windows compatibility laboratory;
6. signed certification and publisher/anti-cheat trust.

## Package contents

```text
docs/       Product, architecture, security, quality, operations, roadmap
research/   Engineering-grade research findings (e.g., legal/licensing spike results)
adr/        Architecture Decision Records
schemas/    Game-profile and runtime-manifest JSON Schemas
examples/   Example per-game compatibility profile
assets/     Optional rendered architecture diagrams
```

## Normative documents

The main product contract is [docs/02_PRD.md](docs/02_PRD.md). The main engineering contract is [docs/04_TECHNICAL_ARCHITECTURE.md](docs/04_TECHNICAL_ARCHITECTURE.md). Contract semantics for profiles/manifests and certification are in:

- [docs/05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md](docs/05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md)
- [docs/07_COMPATIBILITY_CERTIFICATION_SPEC.md](docs/07_COMPATIBILITY_CERTIFICATION_SPEC.md)
- [docs/09_SECURITY_PRIVACY_THREAT_MODEL.md](docs/09_SECURITY_PRIVACY_THREAT_MODEL.md)

## Key decisions

The canonical decision register is [docs/14_DECISION_LOG.md](docs/14_DECISION_LOG.md) and [`adr/`](adr/); this is a curated front-door summary:

- Apple-silicon-only host.
- Modern baseline only: x64 guest games, Direct3D 10/11/12 and Vulkan renderers, storefront-managed installs, a 16 GB certified memory floor, and a rolling current-plus-previous-major macOS window.
- Thin Wine fork with upstream-first generic fixes.
- FEX/ARM64EC-oriented production CPU execution, subject to Phase-0 validation.
- D3D10/11 through a maintained Metal-native provider.
- Owned Metal12 Direct3D 12-to-Metal implementation, kept proprietary under a documented provenance and clean-room protocol.
- Content-addressed immutable runtime storage.
- Per-process policy before normal Windows imports.
- Certified and Custom Mode separation.
- Cloud excluded from the installed launch hot path.
- Developer ID, notarized, user-space distribution without a kernel extension or persistent root daemon.

## Current status

This is a **proposed architecture and product baseline**, not a representation of an implemented product. Time estimates, performance targets, catalog counts, SLOs, and business-model statements are planning assumptions that require validation.

## Visual assets

- [System context PNG](assets/diagrams/system_context.png)
- [D3D12 pipeline PNG](assets/diagrams/d3d12_pipeline.png)
- [Architecture contact sheet](assets/diagrams/architecture_contact_sheet.png)

The technical architecture also contains portable Mermaid diagrams.

## Companion schemas

- [Game Profile Schema](schemas/game-profile.schema.json)
- [Runtime Manifest Schema](schemas/runtime-manifest.schema.json)
- [Example Game Profile](examples/example-game-profile.yaml)

## Package verification

- [Human-readable document manifest](DOCUMENT_MANIFEST.md)
- [Machine-readable SHA-256 manifest](PACKAGE_MANIFEST.json)
