<!-- Author: Timur Isaev -->

# Pinned development runtime

This recipe builds Wine, FEX and the DXMT D3D11 provider in a new private
directory. It never uses the shared build, checkout contents, branch tips or
`releases/latest`. It is a development profile for this pinned macOS 27 host,
not a release, production trust policy or promise of general game support.

## Build

Provide the archive named in `pins.json` (download its exact `toolchain.url`)
and a primary repository containing the pinned third-party Git objects:

```sh
python3 tools/runtime-build/build.py build \
  --source-repo /Users/cleverclosure/Developer/Alloy \
  --toolchain-archive /private/tmp/llvm-mingw-20260616-ucrt-macos-universal.tar.xz \
  --root /private/tmp/alloy-runtime-build --jobs 6
```

The root must not exist. `verify-inputs` accepts the same source/archive
arguments without building. A mismatch fails before the root is created;
there is no fallback to a newer compiler, dirty source or partial build.
Allow at least 14 GiB free. Builds have a two-hour limit per command and kill
only their own process group on failure. Check for another agent's runtime
measurement before starting a build, as required by `CLAUDE.md`.

The driver verifies Git commits and gitlinks, the llvm-mingw archive, patch
and driver bytes, host executables, compiler/SDK trees, Metal compiler tree
and host versions. It exports allowed blobs from the pinned Git objects,
applies pinned patches, extracts a private compiler and builds in a fresh
HOME/TMPDIR with a fixed locale, timestamp and environment. Logs, the exact
recipe, post-overlay source identities and completion record stay in the root.

ADR-0012 exclusions are filtered from the Git tree listing **before any blob
is requested**. DXMT D3D12 and Wine's excluded library are neither exported
nor built. A control deletes forbidden objects from a fixture repository
and still successfully exports the permitted source.

## Host contract and limitations

This is a pinned host build, not a containerized or hermetic operating system.
The recorded OS build, Xcode/SDK and Homebrew tools must already be installed.
The free Xcode Metal compiler component must match the recorded build and
tree; its mount path may change. The driver downloads nothing and accepts no
licenses. Host upgrades require an explicit pin update and fresh proof.
System services, dynamic system libraries and interpreted tool dependencies
are supplied by that host; the recipe does not claim to package an entire OS.

Optional external Wine integrations are disabled to avoid implicit Homebrew
dependencies. Builtin D3D10/11, wined3d and D3D compiler consumers of excluded
sources are disabled; DXMT supplies the D3D11 provider. Audio uses native
frameworks. GStreamer/FFmpeg are disabled, and packaging also applies the
existing release codec omissions. Native binaries use development ad-hoc
signatures, with no signing identity or notarization. UUID load commands are
retained because macOS 27 refuses executables without them.

FEX retains the committed fork's source unchanged. Its established Darwin
configuration reserves x18, uses the TSD slot 6 TEB overlay, 16 KiB host guard
pages, and disables LTO/assertions. The flags are deliberately split between
single-token CMake base flags and release flags: this fork's compiler probe
passes the base flags as one argument.

## Bounded controls

```sh
python3 -m unittest discover -s tools/runtime-build -p test_inputs.py -v
```

These controls need only Python and Git. They prove dirty/switched checkouts
do not leak into an export, a committed source change alters its identity,
toolchain mutations and mutable revisions are rejected, gitlinks match their
pins, excluded blobs are never requested, and escaping symlinks are refused.

See [PROVENANCE.md](PROVENANCE.md) and [results/01-build.md](results/01-build.md).

## Package

```sh
python3 tools/runtime-build/package.py \
  --build-root /private/tmp/alloy-runtime-build \
  --output /private/tmp/alloy-runtime-package
```

Output must not exist, and the build completion record must match its recipe.
The package includes three role layers, an extended recipe identifying the
packager scripts, a component-level SPDX SBOM, unsigned development provenance
and a runtime manifest. Timestamps derive from `sourceDateEpoch`; they identify
the reproducible recipe epoch, not the wall-clock build date. SBOM license
fields use `NOASSERTION`: this is not a license clearance or release SBOM.
The manifest's `reproducible` flag remains false until a separate two-build
proof establishes the result; building once never certifies itself.

Wine runtime files include locale data from the pinned source export. The
packager omits `winedmo.so` and `winegstreamer.so`, exactly as
`spikes/LEGAL-001/codec-clean/stage-runtime.sh` does. It does not ship build
objects, import libraries, tests or absolute symlinks. DXMT Unix dependencies
use relative links back into the Wine layer.

The [layer contract](../../runtime/content-store/Specs/LAYER_FORMAT_V1.md)
defines canonical CBOR, file-tree identity and the raw-block Zstandard
development profile. This profile favors a small audited decoder over
compression efficiency. It accepts native ad-hoc signatures explicitly and
does not claim signed production provenance.

Bounded writer controls run with Python alone:

```sh
python3 -m unittest discover -s tools/runtime-build -p test_layers.py -v
```

For independent full schema validation, install `jsonschema==4.26.0` into a
temporary virtual environment and run its Python with
`tools/runtime-build/validate-package.py /private/tmp/alloy-runtime-package`.
This audit validates both existing schemas and cross-checks component, file
table, recipe, provenance and SBOM digests. It is not required by the builder
and downloads nothing itself. See [results/02-layers.md](results/02-layers.md).

## Import and verify a local generation

```sh
swift build --package-path runtime/content-store --product alloy-runtime-materialize
runtime/content-store/.build/debug/alloy-runtime-materialize import-development \
  /private/tmp/alloy-runtime-package /private/tmp/alloy-runtime-store runtime-proof
runtime/content-store/.build/debug/alloy-runtime-materialize verify \
  /private/tmp/alloy-runtime-store runtime-proof
```

The JSON result contains `path`, the composed `treeDigest`, `generationId` and
the content-store `manifestDigest`. The content-store activation manifest is
a separate ordered-layer document from the package runtime manifest; their
digests need not match. The generation ID connects them. The unsigned CLI is
explicitly restricted to development manifests and compatible hosts.

Verification rejects changed, missing, extra or writable files, changed
symlinks and hard links. It refuses an absent tree and never repairs a
tampered existing one. Import copies and validates archive bytes privately;
the caller's mutable file inode never becomes a CAS object. Native signature
checks are bounded and accept only valid development signatures. Production
trust, launch leases and automatic runtime-tree cache reclamation are outside
this development milestone.

The executable proof uses an external private prefix and has finite command
and diagnostic-volume budgets:

```sh
export ALLOY_RUNTIME_GENERATION=/path/from/the/materializer/json
python3 tools/runtime-build/prove-runtime.py \
  --materializer "$PWD/runtime/content-store/.build/debug/alloy-runtime-materialize" \
  --store /private/tmp/alloy-runtime-store --game runtime-proof \
  --toolchain /private/tmp/alloy-runtime-build/toolchain/llvm-mingw-20260616-ucrt-macos-universal/bin \
  --output /private/tmp/alloy-runtime-proof
```

It checks the active tree, runs native cmd and the unregistered-emulator
control, registers FEX, then requires x64min=42 and ISA smoke=0. Success also
requires a successful Wine builtin-map trace naming the exact FEX image in
that generation and an unchanged runtime inventory. The complete unchanged
issue #104 runner accepts that same path through its `--wine-build` argument. See
[results/03-materialization.md](results/03-materialization.md).
