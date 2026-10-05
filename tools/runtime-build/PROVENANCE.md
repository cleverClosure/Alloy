<!-- Author: Timur Isaev -->

# Recipe provenance

`pins.json` is the authoritative immutable input inventory. Upstream bases
are recorded separately from Alloy fork commits; selected submodules use the
gitlink SHA recorded in each pinned parent. No shared source checkout was
changed to prepare this recipe.

| Input | Origin and reason |
| --- | --- |
| Wine fork `420c70bd…` | Committed `alloy/spike-wine-001` fork, upstream base `5bb70f23…`. |
| FEX fork `ad942313…` | Committed `alloy/task-8-dispatcher-teb` fork, upstream base `0589d9b8…`; no source modifications in this epic. |
| DXMT `e520fea4…` | Committed upstream source, with the two existing GFX-001 instrumentation patches named and hashed in the recipe. |
| `spikes/WINE-001/jit-signal/wine.patch` | Existing committed #111/#125 macOS 27 JIT signal repair. Its fresh native signal bridge prevents the MAP_JIT return loop; copied into private sources by applying the patch, never by copying a mutable checkout. |
| `overlays/winnt.patch` | Captures the previously untracked `spikes/CPU-001/work/darwin-teb-overlay/winnt.h` delta against the pinned llvm-mingw header. Only `NtCurrentTeb` changes from reserved x18 to Darwin TSD slot 6. The archive supplies the original header. |
| `overlays/fex_unixlib_darwin.cpp` | Captures the previously untracked first-party CPU-001 Darwin Unix-call bridge. Six-entry ABI: unsupported operations return `STATUS_NOT_SUPPORTED`; statistics deletion succeeds. This file is outside the FEX source tree. |
| `overlays/wine-excluded-build.patch` | Removes configure registration for the excluded library so Wine's make dependency generator never opens its absent source directory. Disabling the library alone was insufficient. No excluded source was read. |
| `overlays/wine-winedump-metadata.patch` | Updates Wine's diagnostic printer to the ARM64EC metadata names already present in the committed fork header. The old names prevented a clean build. No runtime layout change. |
| `overlays/wine-loaded-image.patch` | Adds one module trace after a successful builtin image map, recording the actual file path, base and size. This lets runtime evidence distinguish a loaded generation image from a lookup or prefix copy. |

The shared Wine checkout had pre-existing changes to
`dlls/ntdll/unix/signal_arm64.c` and `dlls/rpcrt4/ndr_stubless.c`. Neither was
copied, stashed, reset, committed or discarded. The clean recipe uses only
the pinned commit and the tracked patches above. The installed live FEX
binary did not match a retained build; it is not an input to this recipe.

Prototype build failures identified missing Metal tools, an unsupported
UUID-less executable, the absent excluded-library makefile, stale Wine
diagnostic field names, and FEX flag/LTO incompatibilities. Those prototypes
are not evidence of clean reproducibility. Clean builds start after these
fixes with the complete recipe recorded in their root.
