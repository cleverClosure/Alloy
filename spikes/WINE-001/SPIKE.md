# SPIKE-WINE-001 — ARM64-native Wine and the pre-import policy hook

**Author:** Tim Isaev
**Status:** Active (started 23 July 2026)
**Canonical definition:** [doc 16 §3](../../docs/docs/16_OPEN_QUESTIONS_AND_TECHNICAL_SPIKES.md) · validates [ADR-0002](../../docs/adr/ADR-0002-per-process-policy-before-imports.md) / [ADR-0004](../../docs/adr/ADR-0004-thin-wine-fork-and-provider-hooks.md)

**Hypothesis:** Wine can remain close to upstream while exposing a pre-import policy hook and
mixed-architecture (ARM64 native + ARM64EC/WoW64 x64) provider integration on macOS.

## Method (incremental gates)

1. **Toolchain proof** — upstream Wine configures and cross-compiles on macOS/ARM64:
   unix side with Apple clang + brew bison (≥3.8; Apple's 2.3 is too old), PE side with
   llvm-mingw (`aarch64-w64-mingw32`, then the experimental `arm64ec-w64-mingw32` target).
   Deliverable: a reproducible build recipe + every deviation from upstream docs, logged.
2. **Boot proof** — `wineboot` a fresh 64-bit prefix; run trivial ARM64-native PE binaries.
3. **ARM64EC/WoW64 layer** — x64 PE test binaries through the ARM64EC loader path with a stub
   (or Rosetta-backed lab-reference) emulator interface, ahead of FEX integration (CPU-001 gate 4).
   **Native-ARM64 Windows test case:** Kingdom Come: Deliverance II ships a Windows-on-ARM build
   (catalog findings §7.0) — the one full-stack case with zero CPU translation; confirm carrying SKU.
4. **Policy hook** — obtain per-process policy using exact executable identity *before* graphics/
   runtime DLL imports resolve; prove launcher and game processes in one session can select
   different providers; measure hook size (target: small and testable; bounded downstream patch plan).
5. **Rebase drill** — rebase the hook patchset onto a newer upstream revision; record cost.

## Pass evidence (from doc 16)

Hook small/testable; bounded patch plan; no global environment race; child-process identity and
unknown-executable default work; rebase against another upstream revision succeeds.

## Results log

Dated notes in `results/`, newest last, pinned to `third_party/deps.lock` revisions.
Compliance note: the public fork repo (LGPL source + diffs per release, doc 18 model) is created
when the first non-throwaway patch lands — spike scratch patches live in `work/`, never shipped.
