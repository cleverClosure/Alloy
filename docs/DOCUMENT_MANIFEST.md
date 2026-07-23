# MGCR Documentation Package Manifest

**Package version:** 1.2
**Generated:** 23 July 2026
**Files:** 43 plus this manifest and the JSON manifest
**Markdown volume:** 82,436 words across 13,337 lines

The full SHA-256 values are in [`PACKAGE_MANIFEST.json`](PACKAGE_MANIFEST.json).

| Path | Bytes | Lines | Words | SHA-256 prefix |
| --- | --- | --- | --- | --- |
| CHANGELOG.md | 4911 | 53 | 624 | 6525bdbff4e21021… |
| CONTRIBUTING.md | 3931 | 108 | 541 | 84daab7aebbc61e4… |
| README.md | 4464 | 97 | 461 | 9ed2ceaf2e06e04e… |
| adr/ADR-0001-runtime-generation-unit-of-support.md | 2818 | 51 | 374 | 9f6f3f47fb05f6b7… |
| adr/ADR-0002-per-process-policy-before-imports.md | 2662 | 50 | 345 | 11580816559a05ed… |
| adr/ADR-0003-apple-silicon-only.md | 1877 | 49 | 257 | 080665af258f17dc… |
| adr/ADR-0004-thin-wine-fork-and-provider-hooks.md | 2068 | 49 | 276 | 51f49f1e70fec0f8… |
| adr/ADR-0005-fex-arm64ec-execution-path.md | 2326 | 50 | 309 | 3de2141d9808555c… |
| adr/ADR-0006-owned-d3d12-metal-and-reused-d3d11.md | 3289 | 54 | 412 | e1e94eb51e6fb9b3… |
| adr/ADR-0007-content-addressed-immutable-runtimes.md | 1990 | 50 | 236 | af4e59351c06eda1… |
| adr/ADR-0008-certified-and-custom-mode-separation.md | 1919 | 49 | 255 | 65c10383c572bb5f… |
| adr/ADR-0009-cloud-not-on-launch-hot-path.md | 1883 | 48 | 250 | d1874a49fb0e490e… |
| adr/ADR-0010-user-space-developer-id-distribution.md | 2125 | 50 | 284 | 3361b5d209103699… |
| adr/ADR-0011-modern-baseline-only.md | 6542 | 67 | 894 | 646518ab3218bc55… |
| adr/ADR-0012-metal12-provenance-and-clean-room.md | 5487 | 59 | 748 | f7fc5eb9f7b13bbe… |
| adr/ADR-0013-continuous-differential-certification.md | 3487 | 48 | 472 | d605ca499f8ca55c… |
| assets/diagrams/architecture_contact_sheet.png | 415262 | — | — | b53dd0eac95f2c52… |
| assets/diagrams/d3d12_pipeline.png | 286302 | — | — | 09760bb12e3e673e… |
| assets/diagrams/system_context.png | 294223 | — | — | 0b056682149b3567… |
| docs/00_DOCUMENT_MAP.md | 7970 | 189 | 907 | baf5f880dc61447e… |
| docs/01_PRODUCT_STRATEGY.md | 13665 | 291 | 1881 | 4a4eeacaada4bf07… |
| docs/02_PRD.md | 60675 | 661 | 8928 | c583638462edd059… |
| docs/03_UX_AND_USER_JOURNEYS.md | 18694 | 528 | 2678 | 2b3eb17c2ebe9d22… |
| docs/04_TECHNICAL_ARCHITECTURE.md | 190157 | 3721 | 25076 | 3feecf05d3412127… |
| docs/05_RUNTIME_PROFILE_AND_MANIFEST_SPEC.md | 23892 | 673 | 3163 | f7a73e53fd9a8f96… |
| docs/06_API_AND_DATA_CONTRACTS.md | 20584 | 694 | 2439 | aa39724472a2818b… |
| docs/07_COMPATIBILITY_CERTIFICATION_SPEC.md | 18727 | 540 | 2631 | 4030b258d3f7d0da… |
| docs/08_TEST_AND_QUALITY_STRATEGY.md | 19930 | 744 | 2742 | 8e33077d089ea45b… |
| docs/09_SECURITY_PRIVACY_THREAT_MODEL.md | 21758 | 587 | 2880 | cddc87bf81c1f666… |
| docs/10_OBSERVABILITY_OPERATIONS_AND_RELEASE.md | 16858 | 652 | 2312 | 6942a510dec05c1b… |
| docs/11_ROADMAP_TEAM_AND_DELIVERY.md | 19133 | 640 | 2643 | 229f82d66695412a… |
| docs/12_REQUIREMENTS_TRACEABILITY_MATRIX.md | 17061 | 199 | 3364 | 127da601b912645a… |
| docs/13_RISK_REGISTER.md | 17199 | 131 | 2442 | 136e08e2b71e60a6… |
| docs/14_DECISION_LOG.md | 8067 | 76 | 1042 | 21a4306b1eafacd8… |
| docs/15_GLOSSARY.md | 10862 | 208 | 1371 | f37d22124f5629bb… |
| docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md | 13789 | 418 | 1810 | 813be7b09f645b1c… |
| docs/17_PUBLISHER_AND_ANTI_CHEAT_INTEGRATION.md | 13644 | 471 | 1792 | 1d11b8bb92a88d88… |
| docs/18_LEGAL_OPEN_SOURCE_AND_DISTRIBUTION.md | 14446 | 344 | 1792 | dfb527edf7c2cd9a… |
| docs/19_MVP_EPICS_AND_BACKLOG.md | 13172 | 517 | 1701 | 83e65d9c03cbf555… |
| examples/example-game-profile.yaml | 2873 | — | — | 2f5e7d1d196bd993… |
| research/SPIKE-LEGAL-001-preliminary-findings.md | 14967 | 121 | 2104 | ce99d58a7aca34c7… |
| schemas/game-profile.schema.json | 10296 | — | — | 7a3d343c6e876b7b… |
| schemas/runtime-manifest.schema.json | 2583 | — | — | 75d6291ffff892c8… |

## Validation performed (revision 1.2)

- both JSON Schema files parse and pass Draft 2020-12 schema checks;
- the example YAML profile parses and validates against the updated game-profile schema;
- removed legacy provider identifiers (`d3d9on11-dxmt`, `native-opengl`, `wined3d`) appear only in ADR-0011 context and the spec's removal note;
- all Markdown relative links resolve;
- all referenced companion files are present.
