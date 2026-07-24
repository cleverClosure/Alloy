# CPU-001 result 13 — win_smoke's "degenerate rect" was a build artifact (winemac.drv geometry is correct); build-corpus.sh rehabilitated to a green 14-test corpus; jit_pages surfaces and defers the known shear while gaining AVX2 coverage

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `c5785db` · **FEX:** `alloy/spike-fex-001`
darwin-teb build @ `93cae98` · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Why this exists

The last open corpus oddity was `win_smoke` reporting a degenerate client rect
`32866x0` though the window was visible ("green in the morning, degenerate
later"). Chasing it revealed that the report was a symptom of a broken build,
not a `winemac.drv` defect — and that `spikes/CPU-001/testcases/build-corpus.sh`
had drifted so far out of sync with its sources that it no longer built the
corpus end-to-end at all. This note resolves the quirk, rehabilitates the build
script to a green 14-test corpus, and gives the newly-visible `jit_pages`
failure the same honest disposition the rest of the corpus uses.

## The quirk was a build artifact — winemac.drv geometry is correct

`win_smoke` uses GDI (`CreateSolidBrush`, `GetPixel`) and windowing, which are
not auto-linked. Its build line was `build win_smoke ""` — no `-luser32
-lgdi32` — so the exe in the probe was a stale, mis-linked artifact (rebuilding
it today fails to link outright). A mis-linked binary reading uninitialised
stack into a `RECT` is exactly what produces garbage like `32866x0`
(`0x8062 x 0`).

Rebuilt correctly, `win_smoke` is green 6/6 with an exact GDI readback. To rule
out an async-realisation race directly — the title-relevant concern, since games
size their swapchain from `GetClientRect` right after `CreateWindow` — a
three-phase geometry probe read the client rect (0) immediately after
`CreateWindow`, before any message pump; (1) after `UpdateWindow`; (2) after
pumping. Result over 20 runs:

```text
phase0(pre-update)=312x206 phase1(post-update)=312x206 phase2(post-pump)=312x206 pumped=0
```

`312x206` (= 320x240 outer minus the frame) at **all three phases, with zero
messages pumped, 20/20**. `winemac.drv` returns the correct client size
synchronously at `CreateWindow`, exactly like real Windows. There is no
degenerate rect and no realisation race — a positive title-readiness finding.

## build-corpus.sh was broken end-to-end — four latent bugs

Running the script to a clean directory exposed that it had not built the corpus
in a long time (tests were built ad hoc). Four defects, all fixed:

- **`win_smoke` link libraries** — added `-luser32 -lgdi32`.
- **`build()` link order** — the helper placed the per-test flag list `$2`
  *before* the source object, so any `-l` import library is discarded by lld
  (nothing references it yet). Moved `$2` after the source; compile flags are
  position-neutral, so the SEH/AVX/contract flags are unaffected.
- **`x64hello`** — the script built `x64hello`, whose source lives in
  `spikes/WINE-001/testcases`, not this corpus; the line always failed. Removed
  (it is the WINE-001 first-execution smoke, built by that spike).
- **`jit_pages` missing `-mavx2`** — the source uses `_mm256_*` intrinsics; the
  build line was `""`, so it failed to compile. This is why the AVX2 cross-page
  sub-test had never actually run.

After the fixes the script builds **14/14** testcases cleanly.

## jit_pages: the newly-visible failure is the known shear — deferred, not new

With `-mavx2` restored, `jit_pages` compiled and ran for the first time — and
returned 7, then 11. Neither is a new defect:

- Exit 7 was `test_4k_subpage_protection`: a 4 KB sub-page set `PAGE_NOACCESS`
  whose guest read did **not** fault (`protect=00000001` confirmed set). That is
  the documented FEX sub-page shear (`FEX_PAGE_SIZE=4096`; results 04-09), the
  same defect `guard_enforce` case A characterises.
- Exit 11 was the downstream `handled_faults != 2` invariant: with the subpage
  read not faulting, only one fault (the RX-write) occurs, not two.

The inconsistency worth fixing: `guard_enforce` treats "4 KB guard unenforceable"
as the **expected, validated** state and exits 0, while `jit_pages` treated the
identical observation as a hard failure. `jit_pages` now matches the corpus
convention (and the x87 MXCSR disposition in result 12): the shear is reported
loudly as a `KNOWN FEX SHEAR ... non-fatal, deferred FEX item`, the fault-count
invariant is shear-aware, and the run continues. Two consequences:

- `jit_pages` is now green (`faults=1 (subpage guard sheared)`), deterministic.
- The previously-unreachable **cross-page unaligned AVX2 load test now runs and
  passes** — genuinely new coverage proving FEX handles a 32-byte AVX2 load
  straddling a 4 KB boundary correctly.

The shear itself is unchanged: still real, still a deferred founder FEX item,
still characterised by `guard_enforce`. Nothing was hidden — it is now loud in
two tests instead of masquerading as a `jit_pages` hard failure.

## Verification — the corpus is green and honest

Rebuilt via `build-corpus.sh` (14/14), then run under FEX:

- Plain-prefix green set, all exit 0: `memory_semantics`, `fault_cost`,
  `noaccess_inventory`, `jit_pages`, `isa_smoke`, `x87_fp_edge`, `threads_tls`,
  `guard_enforce`, `exception_unwind`, `seh_deep`, `seh_worker`.
- GUI-prefix: `win_smoke` exit 0, exact readback.
- Excluded by design (wedge under item #24, characterised in result 11):
  `seh_concurrent`, `seh_multi`.

No source change to `win_smoke.c` was needed — the fix was entirely in the build
(link libraries). Changed files: `build-corpus.sh` (four fixes) and `jit_pages.c`
(shear disposition + shear-aware fault count).

## Doctrine reinforced

Fifth time today a "runtime defect" was mischaracterised by the one variable its
first framing held fixed — here, the *build*. `win_smoke`'s degenerate rect
looked like a `winemac.drv` geometry bug; correcting the build (link libraries)
made it green and proved the geometry is Windows-equivalent, and the real defect
was a stale build script. As with `-fasync-exceptions`, the GFX recipe, the
concurrency shape, and fp-contraction: vary the fixed variable before trusting
the conclusion.
