<!-- Author: Timur Isaev -->

# Milestone 4: clean rebuild comparison and handoff

On 2026-10-05, two fresh roots built and packaged the same final recipe with
six jobs and the one-command driver. Neither reused a build directory, source
checkout contents, compiler extraction or package output.

| Root | Build seconds | Result |
| --- | --- | --- |
| `/private/tmp/alloy-176-build-i` | 564.894 | Built and packaged |
| `/private/tmp/alloy-176-build-j` | 576.983 | Built and packaged |

Build recipe SHA-256:
`4b5911f0b7e41868fde7242bc4a3cfeb131a9299cffc4b03fc6092ce4c5c88b3`.
Packaged recipe SHA-256 (also identifies the packager and one-command driver):
`fc59f623a416478617cc33b2c1d1275023af7093fda9b48f323fb09c821f17dd`.
Host and source identities are the pinned values from milestone 1; the final
recipe additionally pins the native zstd archive and the native linker options.

The complete invocation for each `i` / `j` root was:

```sh
python3 -B tools/runtime-build/build-generation.py \
  --source-repo /Users/cleverclosure/Developer/Alloy \
  --toolchain-archive /private/tmp/alloy-176-inputs/llvm-mingw-20260616-ucrt-macos-universal.tar.xz \
  --root /private/tmp/alloy-176-build-i \
  --package /private/tmp/alloy-176-package-i --jobs 6
```

The comparison command was:

```sh
python3 -B tools/runtime-build/reproduce.py \
  /private/tmp/alloy-176-build-i /private/tmp/alloy-176-build-j \
  --package-first /private/tmp/alloy-176-package-i \
  --package-second /private/tmp/alloy-176-package-j \
  --report /private/tmp/alloy-176-repro-ij.json
```

## Every shipped byte and artifact

The gate found **832 regular runtime files: 831 byte-identical, one explained
difference, zero unlisted differences**. Path sets, canonical modes and link
targets also matched. Both packages passed independent runtime/layer JSON
schema validation and digest-link checks. All seven artifacts in each sealed
package matched a fresh canonical regeneration from its build.

[04-comparison.json](04-comparison.json) records every package artifact hash.
The Wine and CPU archives and packaged recipe are byte-identical. The graphics
archive differs only through the explained runtime file; its hashes propagate
to the SBOM, provenance and runtime manifest. Regenerating and matching these
metadata bytes prevents a broad metadata exemption from hiding unrelated edits.

The sole exception in [../repro-exemptions.json](../repro-exemptions.json)
is three absolute source-path strings in Metal 27A266a AIR modules embedded in
`providers/aarch64-unix/winemetal.so`. The gate also normalizes the derived
Mach-O UUID and SHA-256 code-page hashes in the verified linker ad-hoc signature.
It retains signature headers, flags, identifier, other fields and padding;
all other bytes must match. Equal-length root names are required for this
bounded comparison. Both actual code signatures pass strict verification.
This is an explained development limitation, not full byte-identical graphics
reproducibility; the runtime manifest's `reproducible` flag remains false.

## Differences removed at their cause

Wine ICU anonymous-namespace symbols retained absolute compiler input paths
in their mangled names despite prefix-map flags. The driver now invokes Wine
configure by the same relative path in both roots. Metal canonicalizes its
source paths independently; relative inputs, prefix-map and compilation-dir
options did not remove them, so an ineffective wrapper was discarded.

The comparison then caught Apple ld 27037.1 selecting different GOT slots in
its large Objective-C message stubs across repeated links with identical
inputs. `-reproducible` alone and `-no_deduplicate` did not fix it; `-ld_classic`
is ignored by this linker. Native DXMT links now use `-objc_stubs_small` and
`-reproducible`, with no change to Windows linker flags. Ten repeated links
per prototype root were stable, and their normalized cross-root bytes matched;
[04-link-controls.json](04-link-controls.json) records that control. Fresh builds
I and J then passed the complete gate. No output binary or signature was patched.

## Real mutations and executable generation

[04-mutations.json](04-mutations.json) records an actual one-byte change from
`0xc00000bbU` to `0xc00000baU` in a private copy of the first-party Darwin bridge.
Compiling both variants changed source, binary and layer digests, and the gate
rejected the changed runtime file. A byte flipped in a private copy of the real
compiler archive caused input-digest refusal before a build root existed.
Neither control touched shared source or the shared runtime.

Package I imported and materialized as:

- Generation: `rtg_2f08b16b119993b38747f8565d732fdb429313341b0a0731e31578f48a8c6252`.
- Store manifest: `sha256:fcf5406df067376fb650ae3b74754c253ffe3db8999a6f0bda44ad3f95793b52`.
- Composed tree: `sha256:dcc1caa40973f1614742a0b2dff486fef5ba24b7fd7073a76aaed7ed6292c4a5`.
- FEX DLL: `sha256:8a55a52c53a1185d305120e35dd8e19d4f515f55199db762f8af1931fca8eec7`.

The README import/prove commands used store `/private/tmp/alloy-176-store-i`,
game `runtime-proof`, build I's private compiler, and output
`/private/tmp/alloy-176-proof-i`. `ALLOY_RUNTIME_GENERATION` named that store's
`runtime-trees/<store-manifest-hex>` path. Native cmd passed, the unregistered
control refused x64 execution without mapping FEX, x64min returned 42, and ISA
smoke passed. The success-only builtin-map trace asserted the exact FEX image
inside this generation. The full unchanged #104 corpus then passed all 27
required FEX outcomes across 13 families, including mutations and atomic tickets.
The runtime inventories and subsequent digest verification stayed unchanged.

[04-runtime-proof.json](04-runtime-proof.json) retains the outcomes, checksums,
actual mapped paths and raw aggregate identity. Raw corpus evidence remains at
`spikes/CPU-001/work/isa-corpus-runs/run-xbqi4k29/aggregate.json`. Build and command
logs remain in the two final build roots and `/private/tmp/alloy-176-*.log`.

## Checks and limits

The bounded suite contains 14 Python tests. It rejects unlisted code changes,
changed signature metadata, malformed Mach-O, changed package metadata and
extra artifacts, alongside the input/export and archive controls. The test-all
engine controls and repository lint passed. The complete idle-host rerun of `tools/test-all --tier fast` passed **42/42
suites, zero failures and zero skips**. Its JSON report has SHA-256
`1a50fcca9dc19e56f87047791ee2dfc3b7f93fc47f314b30e428fdd202129b4f`. Its fields and original report identity are retained in
[04-fast-checks.json](04-fast-checks.json).

Materialization and tamper controls are in the existing content-store suite;
its 91 tests passed locally and in milestone 3 hosted CI. That PR's first CI
attempt failed in the unchanged private-APFS identity disk-pressure control
(the full-volume write unexpectedly succeeded); the unchanged retry passed.
The first idle-host fast run passed 41/42 suites but the existing XPC fixture
checked service removal immediately after `launchctl bootout` and reported it
still registered. Its isolated unchanged rerun passed all nine boundary/cleanup
controls, and a launchd inventory showed no remaining development service.
CodeQL also passed before milestone 3 merged as PR #185. Final milestone hosted
checks are required again by the normal merge gate.

This is a local unsigned development generation for the pinned macOS 27 host.
It proves CPU execution and archive integrity, not a DXMT-rendered game,
performance, release signing, notarization, codec clearance or production trust.
The owner can chmod files, so verification before use remains required.
The host contract and runtime-tree cache limitations remain as documented in
README and the layer spec. Shared main and FEX sources were clean; Wine retained
only its two pre-existing dirty files. No shared runtime or source was modified.
