<!-- Author: Timur Isaev -->

# Milestone 1: isolated pinned build

On 2026-10-05, the command in the README completed in **527.311 seconds** with
six jobs, using root `/private/tmp/alloy-176-build-c` and the exact archive at
`/private/tmp/alloy-176-inputs/llvm-mingw-20260616-ucrt-macos-universal.tar.xz`.
Wine, FEX and DXMT all built successfully. This was a new root, not a resumed
prototype. The source repository was `/Users/cleverclosure/Developer/Alloy`.

Recipe SHA-256:
`4853cc53b61b02a780260b7175adbffcbbe94b10b84e0a847631bb78d17b19d1`.

Post-overlay exported source identities (the diagnostic tree algorithm in
`inputs.py`, before build-system generation):

| Component | SHA-256 |
| --- | --- |
| Wine | `33c6171877502ceaf5427d665bfa4196dd12c04d54075dca634ef4e37e11235e` |
| FEX | `2254534928eac20551609001729f9756ade0b4cb59472826519d07324f4ee16d` |
| DXMT | `079acb58773224c435fddcb3429f44bb1f7f5208fbd20d470d0450fb1328b720` |

The seven `test_inputs.py` tests passed, including planted one-byte toolchain
mutation, mutable revision, mismatched gitlink, forbidden-object deletion,
escaping link and dirty/switched-checkout controls. Source tree changes
produce a different exported identity. The shared runtime was never written.

The host was arm64 macOS build `26A434`, SDK 27.0, Apple clang
`clang-2100.3.34.2`, llvm-mingw 20260616, LLVM 15.0.7 and Metal build
`27A266a`. Exact hashes, source SHAs, arguments and tool paths are in the
recipe. Metal was initially unavailable; the Xcode component was installed
and pinned before the clean build. There was no signing-key or account step.

This milestone proves the build, not guest execution or reproducibility.
The following milestones package its output, verify a materialized runtime,
and compare independent builds. Raw logs remain in the local build root;
they are not shipped as runtime files.
