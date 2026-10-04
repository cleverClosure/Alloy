<!-- Author: Timur Isaev -->

# Synthetic multi-title identity proof

This bounded, offline proof generates three installations from
[`Tests/Fixtures/Breadth/recipe.v1.json`](Tests/Fixtures/Breadth/recipe.v1.json).
It writes only disposable scratch libraries, synthetic anchors/registries, and
the requested result file. The committed real anchor and registry are unchanged.

```bash
bash runtime/store-identity/run-breadth-proof.sh --output /tmp/breadth.json
```

The default runs three measured scans per title and the complete CLI pipeline.
The wrapper immediately replaces itself with the Python owner. Builds use the
shared parser command supervisor, with a 180-second timeout per build; each
native child scan or CLI observation has a 60-second timeout. Iterations
are restricted to 1–5. A subprocess failure, timeout, wrong digest, unexpected
delta, or modified input causes `FAIL` and a nonzero exit. Temporary files are
cleaned on success and ordinary failure.

SIGTERM/SIGINT unwinds the Python owner's scratch context. During a build it
forwards TERM to the shared supervisor and checks its cleanup result before
continuing. Native probes/CLI do not spawn descendants and Python kills/waits
for an interrupted invocation. Repeated cancellation cannot interrupt cleanup.

`--scratch-root PATH` creates and owns a previously absent directory beneath an
existing parent, removing it on completion or cancellation. An outer harness
can place this path inside its own scratch directory and clean it after a forced
kill, which no child-side signal handler can intercept. Existing paths are
refused rather than taken over. Build logs and fixtures are children of this
directory. The shared supervisor arrives through the stacked parser milestone;
`--skip-build` does not need it.

For the performance gate, reuse the same recipe, pinned digests, and measurement:

```bash
bash runtime/store-identity/run-breadth-proof.sh \
  --scan-only --skip-build --iterations 3 --output /tmp/breadth-scan.json
```

`--skip-build` requires current debug binaries. `--scan-only` omits the CLI
controls and labels its result accordingly; it is not full breadth acceptance.
`--smoke` generates only 12 files per title for development and marks its result
`smoke: true`; it is not the 20,000-file proof.

## Deterministic recipe and independent oracle

| App ID | Synthetic title | Files | Installed depots | Executable |
| --- | --- | ---: | ---: | --- |
| 910001 | Synthetic Orchard | 100 | 2 | `Orchard.exe` |
| 910002 | Synthetic 星の港 | 1,000 | 3 | `bin/港の旅.exe` |
| 910003 | Synthetic Atlas Ω | 20,000 | 3 | `engine/Atlas-Win64.exe` |

All three live in one generated Steam library. Every title includes hidden and
empty regular files, Japanese and Cyrillic components, separate NFC and NFD
filenames, a nested path longer than 580 UTF-8 bytes, and a DLC payload. The last
depot is the DLC depot and carries synthetic `dlcappid` metadata. Its size is the
DLC payload size; other payload sizes are distributed across the base depots.
No individual component exceeds filesystem limits. File payloads are a fixed
UTF-8 prefix, app ID, zero-padded index, and relative path, with an empty-file
exception. See [`recipe.py`](Tests/Breadth/recipe.py) for the exact bytes.

Python `hashlib` computes each expected digest directly from these recipe bytes,
without reading scanner output or enumerating the installation. It sorts paths
by their UTF-8 bytes and independently folds
`path + NUL + decimal-size + NUL + lowercase-SHA256 + LF`, as specified in
[`FINGERPRINT_V1` §5](Specs/FINGERPRINT_V1.md#5-aggregate-digest).
[`expected.v1.json`](Tests/Fixtures/Breadth/expected.v1.json) pins the recipe hash,
file counts, byte counts, and aggregate digests. Each observed file entry and
all metadata must equal the independently generated expected record.

Only the small recipe, oracle, and three summary goldens are committed. The
21,100 payload files are generated locally and deleted after the proof.

## Pipeline controls

Before accepting the matrix, a malformed UTF-8 appmanifest must fail with the
exact `invalidUTF8` CLI error and no invalidation. Passing a regular manifest
file as the installation root must fail with the exact scanner
`installRootNotDirectory` error and no fingerprint output. A restored valid
installation must then report unchanged.
The error's object path must identify the selected regular file; macOS aliases
such as `/private/tmp` and `/tmp` may differ in spelling.

Each title runs through the production parser/scanner and production CLI:

1. The scanner's full persisted fingerprint equals the independent oracle.
2. An unchanged observation reports no update and writes no invalidation.
3. Flipping one byte in the DLC file preserves byte/file counts, but emits
   exactly that changed path and the title's own selector ID. The observed and
   superseded aggregates match independently calculated values.
4. Changing only the DLC depot manifest ID emits exactly that depot change,
   preserves the content aggregate, and marks metadata changed with content
   unchanged. The complete observed depot map must match.
5. Repeating each changed observation reuses the same invalidation and identical
   bytes. Restoring the source returns to unchanged.

Snapshots surrounding CLI calls compare input names, content hashes, modes,
inodes, sizes, and modification times. Read-induced access times are excluded.
The synthetic registry contains all three bindings, so a different title's
selector must not leak into an invalidation. Registry artifact hashes refer to
the generated oracle anchors; this does not claim that the CLI verifies evidence
artifact contents, a separate recommendation in `SELECTORS_V1` §4.

The parser currently treats DLC as installed depot identity and payload bytes.
This proof covers that existing behavior, including a DLC-only update; it does
not implement DLC entitlement, store access, or installation policy.

## Production defects exposed

On base `517b47a`, `BuildSelector` refused `Orchard.exe` with
`invalidField("image_hashes")` because it required Sir Brante's filename for
every title. It now requires exactly one safe, exact installed image path.
Launch-policy bindings additionally require the same two reserved aliases and
equal hashes. Existing anchor constants and registry bytes remain unchanged.
New tests reject unsafe, multiple, alias-only, wrong-path, wrong-digest, missing
DLC, changed-depot, and cross-title bindings.

The first independent Unicode comparison also failed: standardizing each
enumerated child URL silently converted the NFC filename `café.txt` to NFD
`café.txt`. The unchanged CLI reported an added and removed path. The scanner
now standardizes only for its existing root-boundary comparison and takes the
relative suffix from the original directory-entry URL. The exact-byte NFC/NFD
regression failed before the fix and passes after it, with an independent
literal aggregate. Existing symlink/FIFO exclusion and mid-scan mutation
refusals remain covered by the package suite.

## Measurement contract

The JSON result has `record: alloy-store-identity-breadth`, `version: 1`, author,
recipe/source hashes, platform, mode, controls, and `scan_samples`. Each sample
contains `metric: scan_cli`, app ID, file count, total bytes, aggregate, iteration,
and `elapsed_seconds`. The interval starts immediately before launching the
existing `FaultProbe scan` and stops after it exits. It includes process startup,
manifest parsing, production scan/hash, canonical encoding, output write, and
readback validation. It excludes compilation, fixture generation, Python oracle
comparison, and CLI update controls. [`sample_scan`](Tests/Breadth/proof.py) is
also callable directly by another Python stdlib harness.

These tiny payloads measure file-count scaling of this debug scan command, not
game-content throughput, a cold-cache benchmark, or a hosted performance budget.
The first recorded scan and subsequent scans are retained separately; fixture
creation and pipeline controls may already have warmed the filesystem cache.

## Local result

On 4 October 2026, the full matrix passed during a coordinated quiet CPU window
on the local arm64 Mac, using base `517b47a` plus this milestone. The nine raw
samples and exact source hashes are committed in
[`local-results.v1.json`](Tests/Fixtures/Breadth/local-results.v1.json).

| Files | Payload bytes | Scan 1 (s) | Scan 2 (s) | Scan 3 (s) | Median (s) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 6,197 | 0.040118 | 0.039080 | 0.038792 | 0.039080 |
| 1,000 | 57,503 | 0.275492 | 0.275287 | 0.277609 | 0.275492 |
| 20,000 | 1,140,508 | 4.994796 | 4.939577 | 4.987969 | 4.987969 |

All 21,100 files matched the independent fingerprints. Both exact malformed
controls passed before the clean matrix; all three titles passed unchanged,
DLC content-change, DLC metadata-only change, restoration, and idempotence
controls. The full package suite passed 31 tests in eight suites on this base;
the pre-existing CLI fixture proof also passed. These counts describe this
milestone's base, not later integrated branches. These are local observations,
not hosted CI wall-clock measurements or a regression threshold; CI integration
and the performance gate are separate milestones.

The later cancellation follow-up preserves the recipe and sample timing span;
the committed measurements remain those collected with the original harness
hash. Its actual wrapper/Python process was sent SIGTERM after a generated
fixture file appeared: it exited 130 and removed the caller-selected scratch
directory. The small complete pipeline also passed through supervised builds
and removed its scratch directory normally.

A second actual top-process cancellation waited until `libproc` observed a real
Swift build descendant, then sent TERM only to the wrapper/Python PID. The owner
exited 130, all four observed process identities stopped, and its selected
scratch directory was removed. Signal deferral here is a Python flag; no blocked
signal mask is inherited by the supervisor or Swift child.
