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
