<!-- Author: Timur Isaev -->

# Milestone 2: canonical runtime layers

Packaged clean build C with `package.py --build-root /private/tmp/alloy-176-build-c --output /private/tmp/alloy-176-package-c4` on 2026-10-05. The runtime manifest and every layer manifest passed the existing Draft 2020-12 schemas with jsonschema 4.26.0. All component, table, recipe, provenance and SBOM digest links passed the independent audit.

| Layer | Archive bytes | SHA-256 |
| --- | --- | --- |
| wine-runtime | 706586422 | `07e8aba60fce75d35b8131dde67b5a37ab303aa82ee175f6a3db978e82a61040` |
| cpu-provider | 5191809 | `1300df5e991bd6ac20f3288daecc791a072a4c94e7d079e60ef13061cf52363c` |
| graphics-provider | 36291400 | `60ee4ce82329554ed4a2fc53b32ed8079c47b430cb3e14b7192c3cba9f46def4` |

Generation: `rtg_43c1e4c9c306e60a45fbf20676509213317e0908f022ac6d172d84dbefd77387`.
Packaged recipe: `sha256:0481eae9ee1bab1f14be752ec1a5cfd74bb926eecb00ea685c76e423731528c8`.
SBOM: `sha256:88a3656a9c81fcd3894ac1b670df40af905c0e1229edf2d16f72c72788348a35`.

Three writer tests passed: deterministic archive bytes despite timestamp changes, changed source bytes changing the digest, unsafe symlink/hardlink/set-id/path rejection, and the extractor fixture identity. The set-id control requires ordinary filesystem permissions; a sandbox that strips set-id bits cannot exercise that control. The actual test run used normal host permissions.

Python 3.14's independent `compression.zstd.decompress` decoded the 10,252-byte known fixture into its 10,240-byte USTAR archive. Tar inspection recovered the expected tool bytes. No alternate codec is mislabeled as Zstandard.

Initial packaging exposed a missing locale-data dependency on first Wine startup. The final packager includes pinned Wine NLS/ICU data and WinRT metadata. No installed shared runtime supplied these files. Optional codec modules are omitted by the same names as the current release pipeline.

Limits: raw Zstandard blocks provide no compression; development provenance is unsigned, the SBOM is component-level, and license assertions are intentionally absent. The package keeps the compilation recipe separate from the current packager script identities in its extended recipe. Guest and materialization results belong to milestone 3.
