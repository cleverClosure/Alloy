# CPU-001 result 01 — initial build survey and constraint discovery

**Author:** Tim Isaev
**Date:** 23 July 2026
**FEX revision:** 0589d9b (shallow tip, see `third_party/deps.lock`)
**Host:** MacBook Pro M2 Pro 16 GB, macOS 26.5.2, AppleClang 17.0.0, cmake 4.2.3, ninja 1.13.2

## 1. Configure attempt (unmodified tree)

`cmake -S third_party/src/fex -B … -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=True`
fails at **CMakeLists.txt:60–68** with the explicit platform gate: *"Unsupported system type
Darwin. FEX only supports Linux and Windows."* Everything before the gate passes: AppleClang 17
accepted as compiler (minimum is Clang 13), pointer-size check passes, `gdb/jit-reader.h`
optional probe cleanly absent. **The macOS refusal is a policy gate, not an organic failure** —
no real build errors have been observed yet because configuration stops by design.

## 2. Host-abstraction seam (read-only tree survey)

- `Source/Windows/` is a first-class host frontend containing `ARM64EC/`, `WOW64/`, `UnixLib/`,
  `Common/`, `Defs/`, and a shipped `wine_builtin.bin` — **upstream FEX already integrates with
  Wine's ARM64EC loader for Windows-on-ARM hosts.** This is the same integration shape Alloy needs
  (FEX as the emulator interface behind Wine ARM64EC), with the host OS beneath it swapped.
- `FEXCore/Source` (the JIT/emulation core) is nearly host-agnostic: **15 files** carry `_WIN32`
  conditionals — concentrated in `Utils/` (Allocator, AllocatorHooks, Profiler, FileLoading) and
  code-buffer/dispatch paths (CodeCache, SharedCodeBufferManager, Dispatcher, Core, CPUID) — and
  **one file** references epoll/futex/memfd. The Linux weight lives in the loader/syscall
  frontends outside FEXCore, which Alloy's Wine-hosted model does not need in full.
- Working hypothesis after survey: the port ≈ a Darwin host layer patterned on `Source/Windows/`'s
  seam plus Darwin branches in ~15 FEXCore files (allocator/W^X/code-buffer/profiler). The known
  hard problems remain Mach exceptions vs. signals, `MAP_JIT` + per-thread W^X, and 16 KB host
  pages — none contradicted yet, none confirmed costly yet.

## 3. Constraint discovered: FEX bans AI-generated contributions

The FEX tree carries a project policy: **"AI must not be used to generate code for contributions
to this project."** Adopted posture for Alloy (binding for this spike):

- AI assistants may **read/analyze** the tree, run builds/tests, and author documents, harnesses,
  and tooling **outside** the FEX tree.
- **All modifications to FEX sources are human-authored** — including trivial ones — so every
  line of a future macOS port remains upstreamable under FEX's policy. A private AI-patched fork
  is technically possible under MIT but is rejected: it would forfeit the upstream relationship
  ADR-0005 assumes and split the tree into upstreamable/non-upstreamable lineages.
- Consequence for solo capacity planning: the FEX port is founder-authored engineering with AI
  limited to analysis and infrastructure; factor this into ADR-0005's validation timeline.

## 4. Next steps (gate 1 continuation)

1. Founder-authored minimal change to pass the platform gate locally (one-line survey patch,
   kept in `work/`, never shipped), then re-run configure → capture the first *organic* failure
   catalogue.
2. Map how `Source/Windows/` is selected at configure time (host frontend switch) to size a
   `Source/Darwin/`-shaped entry point.
3. Enumerate the exact per-file conditional surface of the 15 FEXCore files (classify: allocator,
   W^X, paths, profiling) into a port-plan table.
