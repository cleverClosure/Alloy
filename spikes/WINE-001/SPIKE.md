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

## Gate progress

- **Gate 1 (toolchain proof): closed 23 July 2026** — full build on macOS/ARM64, zero source
  changes (`results/2026-07-23-02-build-complete.md`).
- **Gate 2 (boot proof): CLOSED 23 July 2026.** Native ARM64 PE binaries execute on macOS:
  `wineboot -u` builds a complete prefix (48k-line registry, drive_c, shortcuts), and
  `reg.exe`/`cmd.exe` run to completion with correct output and exit codes
  (`reg.exe`→`Windows 10 Pro` exit 0; `cmd /c "... & exit 42"`→exit 42). Kill-chain:
  loader SIGKILL (sub-4 GB `__PAGEZERO` denial) → shared-user-data map failure (KUSD at
  0x7ffe0000, below the hard 4 GB arm64 VA floor) → TEB-block below-2 GB placement → PE
  crash reading the TEB via **x18**, which Darwin zeroes on every kernel entry. Fixes:
  drop the loader `-pagezero_size` on aarch64; relocate `KUSER_SHARED_DATA` to
  0x7ffe00000000; lift the `limit_2g` TEB constraint; **source the TEB from pthread TSD
  slot 6 (`[tpidrro_el0]+0x30`) instead of x18** across `NtCurrentTeb()` (both GNUC and
  the load-bearing MSVC `-target aarch64-windows` branch) and the hand-written arm64
  dispatchers. Analyses: `results/2026-07-23-03-macos26-exec-policy-and-va-floor.md`,
  `results/2026-07-23-04-teb-in-tsd-and-first-pe-execution.md`.
- **Gate 3 (ARM64EC/WoW64 x64 layer): Wine side PROVEN 23 July 2026.** x64 guest PEs
  (freestanding and full-CRT/TLS-callback 4K-aligned) load through the EC loader; the
  emulator interface resolves and initializes (`ProcessInit` → feature probes →
  `ThreadInit`); the first x64 transfer (TLS callback / entry point) reaches the stub's
  `ExitToX64`; exit 0, no faults; native ARM64X path regression-free. The gate-3 EACCES
  was **not** capped max_protection (live region dump: `max = RWX`) — it was macOS's
  RWX-denial on non-MAP_JIT memory hitting 4K-guest-in-16K-host page unions, compounded
  by three more defects (unchecked metadata unprotect + pre-init NULL-dispatch recursion;
  lld FFS exports taken raw for the dispatch trio; emulator import-chain stamping order).
  Fixes: Wine `mprotect_exec` drops EXEC when RWX is denied (guest x64 pages don't need
  host EXEC under an emulator — exec faults route to `KiUserEmulationDispatcher` by
  design); `arm64ec_process_init` resolves the dispatch trio through
  `arm64ec_redirect_ptr` (**required by FEX's lld-built dll too**); stub rebuilt
  freestanding (ntdll-only imports), 64K-aligned, DbgPrint logging, noreturn trio.
  Full kill-chain + evidence: `results/2026-07-23-06-gate3-wine-side-proven.md`.
  Remaining for full gate 3: FEX Darwin port + swap-in (founder-only, = CPU-001 gate 4).
  Still deferred: `env.c`/LDT `limit_2g` sites.
- **`wineboot`/explorer CPU-spin follow-up: RESOLVED 24 July 2026.** The spin was a
  SIGSEGV storm: four modules (win32u message pump, kernelbase/kernel32) still read
  `KUSER_SHARED_DATA` at the architectural `0x7ffe0000`, which is below the arm64-macOS
  4 GB VA floor (empirically hard: exec SIGKILLs binaries with pagezero < 4 GB; the floor
  is the task's min VM address, not a removable mapping). Repointed to the relocated USD;
  cold boot 4–5 min/never → **12 s**, zero faults, no lingering processes. The VA floor is
  a **standing FEX design input** (games inline `0x7ffe0000` reads; translate-time literal
  remap + trap-and-emulate fallback). Full analysis:
  `results/2026-07-24-07-wineboot-spin-va-floor-usd.md`.
- Follow-ups (not gate-2 blockers): full graphical boot needs a FreeType + `winemac.drv`
  build (font/GUI backend); service-subsystem autostart faults; `get_core_id_regs_arm64`
  stub for guest CPU features.

Wine patches live on local branch `alloy/spike-wine-001` in `third_party/src/wine`
(`0e693a0` loader flags + KUSD + teb_block; `efd41b9` TEB-from-TSD; `8870df9` EC TEB
dispatchers + errno logging; `24bad68` gate-3 close: `mprotect_exec` RWX→RW fallback,
dispatch-trio redirection, region-dump + low-pc-fault diagnostics; `b93a982` USD
readers repointed above the VA floor + unresolved-fault storm detector).

## Results log

Dated notes in `results/`, newest last, pinned to `third_party/deps.lock` revisions.
Compliance note: the public fork repo (LGPL source + diffs per release, doc 18 model) is created
when the first non-throwaway patch lands — spike scratch patches live in `work/` or on local
branches in the pinned checkouts, never shipped.
