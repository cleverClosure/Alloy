# WINE-001 policy probe

**Author:** Timur Isaev

This probe compiles a deterministic, fixed-layout policy snapshot and passes it to the Wine
startup hook through an inherited read-only file descriptor. The launcher, its known game child,
and an unknown child all statically import the same `alloygraphics.dll` name. The snapshot routes
that import to three distinct provider directories:

| Process | Match | Expected provider |
|---|---|---|
| `launcher.exe` | exact SHA-256 | `dxmt` marker |
| `game.exe` | exact SHA-256 | `metal12` marker |
| `unknown.exe` | no exact entry | restricted default marker |

Run the end-to-end proof after building Wine in `spikes/WINE-001/work/build-2`:

```sh
spikes/WINE-001/policy-probe/run-policy-proof.sh
```

The runner rebuilds all guest artifacts, compiles the same snapshot twice and compares the bytes,
unlinks the snapshot after opening it read-only, launches the three-process tree in one Wine
session, and verifies policy traces, provider DLL paths, process results, and the unknown default.

## Snapshot v2

New runtime development uses the [v2 contract](SNAPSHOT_V2.md) and the pinned
runtime builder, with an isolated materialized generation. The command above is
the retained v1 historical proof; it is not a v2 runtime test.

```sh
export ALLOY_RUNTIME_GENERATION=/path/from/verified/materializer/output
python3 spikes/WINE-001/policy-probe/prove-v2.py \
  --materializer /path/to/alloy-runtime-materialize \
  --store /path/to/private-store --game policy177 \
  --toolchain /path/to/pinned/llvm-mingw/bin \
  --output /private/tmp/new-policy-proof
```

Build `alloy-policy-compile` in this package first. The proof compiles synthetic
native and x64 guests, verifies the runtime selected by the environment, uses a
fresh private prefix, and checks inside DLL initialization as well as guest entry.
See [milestone 2 evidence](results/02-enforcement.md). Provider names are synthetic
markers, not a D3D rendering or graphics-capability claim.
