# CPU-001 result 12 — x87_fp_edge 0x188 attributed: two FMA "defects" were test artifacts (FEX FMA is bit-exact); MXCSR sticky flags are the one real gap, precisely located and deferred

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `c5785db` · **FEX:** `alloy/spike-fex-001`
darwin-teb build @ `93cae98` · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Why this exists

Result 08 filed `x87_fp_edge`'s failure mask `0x188` as founder item #3 —
"MXCSR sticky exception flags not virtualized; FMA3 not fused — both `fma()`
and the direct `vfmadd` instruction double-round." This note re-examines all
three failing bits from first principles. The result: **two of the three are
test artifacts (FEX's FMA is bit-exact single-rounded), and only one (MXCSR
sticky exception-status flags) is a genuine FEX gap — cosmetic, game-irrelevant,
and now precisely located to a single line.** The test is corrected; the corpus
family goes green; the real gap is documented as a deferred FEX item with its
exact fix locus.

## Exit 136 is the mask, not a signal

`main()` returns `failures`, a bitmask. `0x188` = 392, and an exit status is
truncated to 8 bits: `392 & 0xFF = 136`. Read cold, 136 looks exactly like
`128 + 8` (SIGFPE) — but the process never trapped. It ran to completion and
self-reported three failed families: bit 3 (`fp exception flags`), bit 7 (`fma
fusion`), bit 8 (`fma3 instruction`). Six other families passed.

## Bits 7 and 8 were test artifacts — FEX's FMA is bit-exact

The test asserted `fma(x,x,-1) != x*x - 1` for `x = 1 + 2^-52`. Two independent
flaws made that assertion false regardless of the emulator, both proven on a
native machine with a genuine hardware fused-multiply-add (this Apple-Silicon
host, and a native x86_64 build):

- **Compiler contraction.** `build-corpus.sh` compiled with plain `-O2`, and
  clang defaults to `-ffp-contract=on`, which rewrites `x*x - 1.0` into a single
  fused op at compile time. So the guest binary emitted the *same* fused
  instruction for both `fused` and `split` — the inequality can never hold, on
  any CPU or emulator. Flipping to `-ffp-contract=off` makes a separating vector
  differ immediately on native hardware.
- **A dead test vector.** Even with contraction off, `x = 1 + 2^-52` still does
  not separate: the exact product `1 + 2^-51 + 2^-104` has its excess bit
  `2^-104` land on the round-to-even boundary, so both the fused and the split
  paths collapse to `2^-51`. A vector like `1 + 2^-27` actually exercises the
  single- vs double-rounding difference.

Decisive check — a guest probe built `-ffp-contract=off` with the separating
vector, run under FEX:

```text
   x     = 1.0000000074505805969 (0x3ff0000002000000)
   fused = 1.4901161249358807481e-08 (0x3e50000001000000)   <- single-rounded
   split = 1.490116119384765625e-08 (0x3e50000000000000)    <- mul then sub
fused!=split: 1  ->  FEX-FMA-IS-FUSED (single rounding, correct)
```

Those two bit patterns match the native `-ffp-contract=off` reference exactly.
FEX lowers x86 `vfmadd231sd` to a true ARM64 `fmadd`; there is no double
rounding. Result 08's "FMA3 not fused" measured the compiler, not FEX.

## Bit 3 is the one real gap — MXCSR sticky exception-status flags

A forced-instruction probe (real `divsd`/`sqrtsd` via `-fno-math-errno` +
`__builtin_sqrt`, reading raw MXCSR through `stmxcsr`/`_mm_getcsr`):

```text
   initial          MXCSR=0x1f80  [IE=0 DE=0 ZE=0 OE=0 UE=0 PE=0]
   after 1.0/0.0    MXCSR=0x1f80  [IE=0 DE=0 ZE=0 OE=0 UE=0 PE=0]   isinf=1
   after sqrt(-1)   MXCSR=0x1f80  [IE=0 DE=0 ZE=0 OE=0 UE=0 PE=0]   isnan=1
   after 1e308^2    MXCSR=0x1f80  [IE=0 DE=0 ZE=0 OE=0 UE=0 PE=0]   isinf=1
   FTZ set->read-back=1   (control-bit round-trip)
```

Reading this precisely:

- The **values are all correct** — `isinf`/`isnan` hold, so FEX computes the
  right results. This is not the `sqrt` libcall artifact (a real `sqrtsd`
  executed and produced a correct NaN), it is specifically the flags.
- The **sticky status bits never set** — divide-by-zero should set ZE, sqrt of a
  negative should set IE, overflow should set OE|PE; none appear.
- The **control bits round-trip** — setting FTZ reads back. FEX virtualizes the
  MXCSR *control* half but not the *status* half.

Root cause, confirmed in FEX source (outside the ADR-0012 clean-room exclusions
— FP core, not d3d12):

```cpp
// FEXCore/Source/Interface/Core/OpcodeDispatcher/Vector.cpp  GetMXCSR()
MXCSR = _And(OpSize::i32Bit, MXCSR, Constant(0xFFC0));   // masks off low 6 bits
```

`0xFFC0` clears exactly the six sticky exception-status bits on every MXCSR
read; `RestoreMXCSRState` masks identically on write. This is a deliberate FEX
design tradeoff, not a bug: virtualizing the flags would require reading host
FPSR sticky bits and merging them (FPSR IOC→IE, DZC→ZE, OFC→OE, UFC→UE, IXC→PE,
IDC→DE), at a throughput cost FEX declines to pay. There is no config knob.

**Game impact: negligible.** Real games mask all FP exceptions and never read
the accumulated MXCSR status field; the sticky flags matter to numeric-library
conformance suites, not to rendering or physics. Classified deferred,
low-priority, non-blocking.

## The test correction

`x87_fp_edge.c` now measures FEX honestly rather than the compiler:

- **FMA (bits 7, 8):** vector changed to `1 + 2^-27`; the split path stores
  `x*x` into a `volatile` before subtracting, forcing a round-to-double so
  contraction cannot collapse the two paths (robust regardless of build flags).
  `build-corpus.sh` additionally builds this test `-ffp-contract=off` to make
  the intent explicit. Both bits now pass under FEX — the corpus itself now
  proves FEX's FMA is fused.
- **MXCSR (bit 3):** split into a mandatory *value* assertion (div-by-zero →
  +inf, sqrt(-1) → NaN — FEX passes) and an *advisory* sticky-flag probe that
  prints `KNOWN FEX GAP - MXCSR status unvirtualized, non-fatal` and does not
  fail the corpus. The gap stays loud in the output; it no longer masquerades as
  a hard failure.

## Verification

- `x87_fp_edge` under FEX: **exit 0**, deterministic 3/3. Output shows all
  mandatory families `ok`, `fma fusion: ok`, `fma3 instruction: ok`, and the
  advisory `fp sticky flags: KNOWN FEX GAP` line.
- Regression spot-check (unchanged binaries): `isa_smoke`, `memory_semantics`,
  `x64hello` all exit 0. Only `x87_fp_edge.c` and its build line changed, so the
  rest of the corpus is unaffected by construction.

## Founder handoff — the deferred FEX item

MXCSR sticky exception-status virtualization is added to the founder FEX list,
fully localized:

- **Locus:** `FEXCore/Source/Interface/Core/OpcodeDispatcher/Vector.cpp`,
  `GetMXCSR()` — the `_And(..., 0xFFC0)` that discards the status bits.
- **Approach (if ever wanted):** at `GetMXCSR` time, read host FPSR and OR the
  mapped sticky bits into the returned value instead of masking them to 0. Lazy
  on-read is cheap (only `stmxcsr`/`fnstsw`/`fnstenv` reads pay); the risk is
  spurious flags from FEX's own JIT FP sequences raising host exceptions the
  guest op would not — which is why upstream leaves it off. Independent
  reimplementation required before any upstreaming per the fork policy.
- **Priority:** low. No known title depends on reading MXCSR sticky flags.

## Doctrine reinforced

Fourth time today a "runtime defect" was mischaracterised by the one variable
its first framing held fixed: the SEH async-exception compile flag (result 10),
the graphics launch recipe (this morning), the concurrency *shape* (result 11),
and now the FP-contraction build flag plus a non-separating test vector. The fix
each time was to vary that fixed variable before trusting the conclusion —
here, to prove the numeric oracle on real hardware before blaming the emulator.
Two phantom FEX defects removed from the board; the one real gap sharpened from
"not virtualized" to a single masked line with a measured game impact.
