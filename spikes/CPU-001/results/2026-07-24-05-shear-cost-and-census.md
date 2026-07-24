# CPU-001 result 05 — shear economics: fault cost measured, occurrence censused

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `61bf569` · **FEX DLL:** darwin-teb `0a1c3d39…` ·
**Hardware:** MacBook Pro M2 Pro, 16 GB, macOS 26.5

Result 04 isolated the 4 KB sub-page shear defect and posed the design question. This result
supplies the two numbers the decision needs: what one enforcement fault costs, and how often
shear actually happens.

## Recovered provenance: the runtime rested on four uncommitted patches

Committing the census surfaced that the working tree carried substantial uncommitted work
from the previous session — load-bearing for every result-04 measurement. Now split into
honest fork commits:

- `7b1b3be` **real ARM64 ID registers on macOS** — `get_core_id_regs_arm64` (previously a
  stub) reports LSE/CRC32/AES/SHA/DotProd… via sysctl, which is how FEX learns the M2's
  features.
- `0dfe17e` **the ARM64EC x18 TEB contract on macOS** — completes the x18 story beyond
  result 04's build-input fix, with two mechanisms: (a) `handle_arm64ec_teb_load` in the
  segv path traps `ldr Xn, [x18, #0x60|#0x1788]` when the kernel has zeroed x18 and
  emulates the load from the real TEB; (b) syscall-return asm and naked dispatch-trio
  wrappers re-materialize x18 from TSD slot 6 before entering external PE code that assumes
  the Windows convention. Result 04's "JIT-emitted x18 paths un-probed" caveat is therefore
  resolved: remaining inline x18 TEB reads are trapped and emulated, entry paths restore it.
- `3ffe324` **MAP_JIT for anonymous RWX views** — `map_view` requests `MAP_JIT` for
  no-fixed-base RWX allocations and threads `mmap_flags` through the mapping chain. This is
  how FEX's RWX code cache exists at all under macOS's categorical RWX denial.
- `61bf569` **the shear census itself** (this result's instrument).

## Fault cost (fault_cost.exe, x64 guest under FEX, two runs)

| Operation | Run 1 | Run 2 |
| --- | --- | --- |
| Plain dependent read | 0.335 ns | 0.345 ns |
| Handled access violation (fault → Wine → guest handler → resume) | 8,911 ns | 8,858 ns |
| `VirtualProtect` call | 846 ns | 853 ns |
| `VirtualQuery` call (syscall baseline) | 379 ns | 363 ns |

One guest-dispatched fault ≈ **8.9 µs ≈ 26,600 plain reads**. That is the upper bound for a
spurious fault under a restrictive-union design when resolution goes through guest exception
dispatch; a Wine-internal fix-and-retry would cost less but stay in the microsecond class.
Scale reference: a hot address absorbing 1,000 spurious faults/s costs ~0.9% of a core;
100,000/s consumes ~89% of a core.

## Shear census (fork commit `61bf569`)

`set_page_vprot`/`set_page_vprot_bits` are the only vprot mutation primitives, and only the
boundary host pages of a mutation can become heterogeneous — so a check there sees every
transition. Rate-limited ERR logging in the storm-detector idiom; the **noaccess class**
counts host pages where a committed inaccessible guest page (NOACCESS or guard) coexists
with a committed accessible one — the semantics-losing case.

**Cold boot, fresh prefix (all system processes): 545 shear events — noaccess class: 0.**

Observed classes, decoded from the logged vprot bytes (0x21 R, 0x23 RW, 0x29 R+writecopy,
0x27 RWX, 0x20 committed-noaccess, 0x00 uncommitted):

- **Commit-boundary tails** (`[21 00 00 00]`, `[23 23 00 00]`, …) — ubiquitous; includes
  the relocated KUSER_SHARED_DATA page. Consequence: reads of uncommitted tail VAs inside
  the host page succeed instead of faulting. Benign for correct programs, wrong for
  fault-probing ones.
- **Image-section mixes** (`[29 21 21 21]` view image, and `[21 21 21 29]` on the guest
  x64 exe at 0x140000000) — R and R+writecopy sections sharing host pages. Consequence:
  cross-section write protection between adjacent image pages is weakened. No EXEC-bearing
  unions were observed anywhere (EC modules are 64K-aligned by construction; guest x64
  EXEC never needs host EXEC under the emulator).

**Guest corpus runs: ~35 events each — noaccess class: 3, identical across all tests**,
none created by the test logic:

1. `[27 27 27 20]` — **FEX's own JIT code cache** allocates RWX chunks with a NOACCESS
   tail page; the tail guard is sheared, so cache overruns would not trap. FEX-side
   alignment fix (founder).
2. `[23 23 23 20]` / `[23 20 00 00]` at 0x7ffe… — **thread-stack hard NOACCESS barriers**
   sheared against committed stack pages: an overflow racing past the guard corrupts
   instead of trapping. Wine-owned layout → host-page-align the barrier (next fork patch).
3. `jit_pages`'s deliberate interior NOACCESS registers as the 4th event — classifier
   validated end-to-end.

## An asymmetry worth exploiting

`get_unix_prot` returns PROT_NONE for any vprot with `VPROT_GUARD` set, and the census
confirmed the union byte carries the guard bit. So **guard shear fails restrictive** (the
whole host page goes inaccessible; sibling accesses spuriously fault into the guard
machinery, which the stack-growth path at least handles), while **NOACCESS shear fails
permissive** (silent access). The dangerous silent class is NOACCESS-only, which the census
shows is rare and, today, entirely runtime-owned (FEX cache, Wine stacks) rather than
app-created.

## Verdict for the design decision

- **Global restrictive union is rejected by the data**: 545 shear events in one boot are
  overwhelmingly benign commit-tails and image-section mixes; converting them all into
  8.9 µs-class spurious-fault surfaces buys nothing the workloads need.
- **The observed semantics-losing cases are runtime-owned and individually fixable**:
  host-align Wine's stack NOACCESS barrier (fork patch, regression-provable — census
  noaccess baseline should drop 3 → 1); host-align FEX's cache tail guard (founder, FEX
  tree).
- **App-created interior NOACCESS remains the only unknown** — frequency in real titles is
  exactly what the census now measures for free in every future run (Steam client under
  STORE-001, portfolio titles under gate 5). Decide enforcement machinery only if the
  census ever shows a nonzero app-created noaccess class.
- Guard-class shear needs no new machinery today but inherits spurious sibling faults;
  the 8.9 µs number bounds that cost too.

## Next

1. Fork patch: host-page-align thread-stack barrier/guard layout; verify census 3 → 1.
2. Founder: align FEX cache tail guards; root-cause the per-thread DLL+0x1018 absorbed AV.
3. Keep the census permanently (storm-detector precedent); read it in every STORE-001 and
   gate-5 session — it is the standing answer to "do real games create interior NOACCESS".
4. Fold this evidence into the shear ADR when the Steam-client data point exists.
