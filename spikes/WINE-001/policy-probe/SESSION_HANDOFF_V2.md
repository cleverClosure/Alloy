<!-- Author: Timur Isaev -->

# Session launcher handoff: snapshot v2

The session-launch epic can consume the [v2 wire contract](SNAPSHOT_V2.md) and
the profile compiler's [coverage contract](../../../runtime/profile-compiler/Specs/SNAPSHOT_V2.md).
The development proof does not authorize production sessions or change the
session-service, content-store or client app.

## Required sequence

1. Resolve the launch plan against trusted profile and runtime inputs. Bind each
   provider directory to the selected, verified runtime generation. V2 identities
   are executable SHA-256 values, not paths or process names. Two different
   policies for the same executable hash require a future context-aware format.
2. Use `PolicySnapshotExporter.export`. Honor every `notYetLowered` entry and the
   complete launch specification's `runtimeReady` and `productionEligible` gates.
   Encoding can succeed for a diagnostic projection with gaps; that is not
   permission to launch. The development exporter is for trusted resolved inputs
   and does not replace the full profile compiler's evidence validation.
3. Write the bytes into a private file, close all writable handles, open it
   read-only, and unlink it. Keep its read-only descriptor inheritable. Compute
   the complete-file SHA-256 from those exact bytes and compare it to the export's
   `digest`; do not substitute either embedded digest for the complete-file hash.
4. Set `ALLOY_POLICY_SNAPSHOT_FD` to the decimal descriptor number (at least 3),
   `ALLOY_POLICY_SNAPSHOT_SHA256` to the 64 lowercase hex digits **without** the
   `sha256:` prefix, and `ALLOY_POLICY_REQUIRED=1`. Preserve the descriptor and all
   three fields across every child launch. The proof uses normal Windows
   `CreateProcessA` and verifies the inherited policy in each child's `DllMain`.
5. Launch the exact materializer-verified runtime tree with a private prefix.
   Verify the actual builtin FEX mapping against that tree. Copying a translator
   into the prefix's system32 does not select Wine's builtin translator.
6. Treat any named policy failure as a failed process launch. Never retry by
   stripping policy transport or downgrading to v1. Track the whole session's
   children and report their failures; one failed child need not terminate its
   parent automatically. Close owned descriptors and clean up only that prefix.

The Wine hook checks bounded copied bytes, expected and internal hashes, and
every canonical entry before selection. It applies CPU, environment, cwd,
provider path and DLL routes before guest imports. An invalid cwd or incompatible
CPU fails before imports as well. Unknown images receive entry zero. When all
three transport fields are absent, Wine intentionally retains stock behavior;
the launcher must not remove all three from a managed session.

## What the synthetic proof establishes

One native launcher selects the synthetic `dxmt` marker DLL, starts an x64 game
that selects the synthetic `metal12` marker DLL through FEX, and then starts a
native unknown child that selects `restricted`. All three observe distinct
environment and cwd values during DLL attach, before their entry points.
These marker DLLs prove routing; they do not claim D3D rendering coverage.

The explicit development default limits CPU admission to pure ARM64 and denies
the `alloyblocked` DLL even though that DLL exists and loads in the stock control.
An unlisted x64 executable is refused instead of inheriting the game's FEX
allowance. This is a restricted **CPU/DLL default**, not a network or filesystem
sandbox. The proof requests neutral `conservative` synchronization, `allow`
networking and `off` optional diagnostics. It does not claim to implement the
complete profile compiler's conservative `deny`/`crash-only` default; those remain
visible coverage gaps and continue to block complete launches that request them.

Native CPU means pure ARM64 admission in this runtime. Hybrid ARM64EC still
requires translator callbacks and is rejected by `native-arm64ec`. FEX selection
uses the fixed builtin image, independent of mutable prefix registration.

Integrity failures are distinct: changed bytes with the original expected hash
fail `policy-expected-digest`; changed bytes with a recomputed expected hash but
stale embedded checksums fail `policy-integrity`; a missing descriptor fails
`policy-descriptor-missing`. The expected digest binds bytes to the caller's
plan; it is not a signature or a defense against a caller that replaces both.

## Reproduce the proof

Use the pinned runtime build recipe and materialize its completed generation.
Build `alloy-policy-compile` and the profile compiler's `alloy-snapshot-export`.
The following paths are explicit local inputs; no shared runtime is rebuilt:

```sh
ALLOY_RUNTIME_GENERATION=/absolute/materialized/runtime-tree \
  python3 spikes/WINE-001/policy-probe/prove-v2.py \
  --materializer /absolute/alloy-runtime-materialize \
  --store /absolute/private-store --game policy177 \
  --toolchain /absolute/llvm-mingw/bin \
  --compiler /absolute/alloy-policy-compile \
  --exporter /absolute/alloy-snapshot-export \
  --corpus --output /absolute/new-proof-directory
```

The harness checks the active tree before and after, creates its own prefix and
synthetic guests, imposes per-process deadlines and log bounds, records loaded
FEX paths, and writes `proof.json`. The corpus runs each of 196 malformed inputs
through a separate actual Wine process and requires a named failure with no
guest import or entry marker. Host ASan/UBSan and Swift corpus controls remain
separate, complementary checks.
