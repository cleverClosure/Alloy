# CPU-001 result 21 — the x18 fault tax was real after all: result 17 fixed one of two copies of the dispatch preamble, and converting the other takes a title boot from 400,000 absorbs to 8

**Author:** Tim Isaev
**Date:** 25 July 2026
**FEX:** `alloy/task-8-dispatcher-teb` @ `5944be0` (stacked on `alloy/task-20-null-call`) ·
**Wine:** `alloy/task-8-absorb-attribution` @ `54048cb` ·
**Title:** *The Life and Suffering of Sir Brante* build 24280929 ·
**Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

Issue #8 asked to remove a dispatcher-gadget x18 fault tax. Result 17 measured
the change and reported the premise unsupported. That conclusion was wrong, and
this result explains why in a way that matters beyond this issue:

- **FEX has two implementations of the ARM64EC dispatch preamble.** `Module.S`
  holds static gadgets; `Dispatcher.cpp`, `MiscOps.cpp` and `Arm64Emitter.cpp`
  **emit a second copy at runtime**. `ce60231` converted the first and left the
  second reading the TEB through x18 (§2).
- **All the absorbs came from the second copy.** Attributed by teaching the
  backstop to describe the faulting page rather than name it (§1).
- **Converting all six emit sites takes an entitled title boot from over
  400,000 absorbs to 8**, and the residual 8 are a different site class (§3).
- **The cost was never the reason to do it.** Measured in-handler time for
  400,000 absorbs is 6.9 ms across a 100 s boot — 0.007%. The count looked
  alarming; the price does not (§4).
- Corpus 31/31 (§5).

## 1. Attribution: the sites were never in any image

Result 17 §2 recorded the four faulting instructions and their offsets, noted
they used x8/x10/x11 rather than the gadgets' x16/x17, and left their origin
unidentified — the base matched no guest module FEX logs. Correlating against
*every* module Wine loads (which result 17 did not do) showed why: nothing
occupies that address range at all. Executables load at `0x140000000`, builtin
DLLs at `0x6FFFF…`, and the absorb base was `0x100d90000` in result 17 and
`0x102e60000` here — **it moves between runs**.

So the code is dynamically allocated, and no module search could ever have found
it. Teaching the backstop to describe the page resolved it in one run:

```text
x18 backstop absorb #0 pc 0x102e60124 instr f940324a offset 0x60
attribution: 0x102e60124 is a wine view base 0x102e60000 size 4000
             view-protect 1127  page-vprot 27
region 0x102e60000-0x102e64000 prot 7 max 7 share 2 tag 0
```

`view-protect 0x1127` carries `VPROT_JIT`; the Mach region is RWX. A
runtime-generated JIT buffer, allocated through Wine.

## 2. Two copies of the same preamble

| copy | location | converted by |
| --- | --- | --- |
| static gadgets | `Source/Windows/ARM64EC/Module.S` | `ce60231` (result 17) |
| generated, 3 sites | `FEXCore/…/Dispatcher/Dispatcher.cpp` | **this change** |
| generated, 2 sites | `FEXCore/…/JIT/MiscOps.cpp` | **this change** |
| generated, 1 site | `FEXCore/…/ArchHelpers/Arm64Emitter.cpp` | **this change** |

All six read `TEB_PEB_OFFSET` (0x60) or `TEB_CPU_AREA_OFFSET` (0x1788) through
x18, via the scratch registers `TMP1`/`TMP2` — which is exactly why the faulting
instructions used x8/x10/x11. Result 17 spotted that discrepancy and drew the
correct local conclusion ("these are not `Module.S`") but the wrong global one
("the premise is unsupported"). The premise was right; the patch reached one
copy of two.

This also corrects a smaller claim. Result 17 recorded that the gadget loads
"were correct by accident of Wine's preamble" setting x18 first. Not accidental —
**load-bearing**, because the generated copy depended on it.

## 3. Effect

Entitled title, headless boot, 100 s cap, identical configuration:

| | absorbs | in-handler time |
| --- | ---: | ---: |
| before | > 400,000 | 6,910,402 ns |
| 3 of 6 sites converted | > 100,000 | 1,554,452 ns |
| all 6 converted | **8** | ~70,000 ns |

The residual 8 are at offset **0x30**, not 0x60 or 0x1788 — the TSD slot itself,
a different site class from the dispatch reads this issue concerns. They are not
addressed here and are not claimed to be.

The boot reaches Unity's game manager in every configuration.

## 4. The cost, and why it is not the justification

Done-when item 2 required a wall-clock measurement, because a count is not a
cost. Timing the absorb path directly:

**400,000 absorbs cost 6.9 ms of in-handler time across a ~100 s boot — 0.007%
of wall clock, about 17 ns each.**

That is a **lower bound**: it excludes the kernel exception entry and signal
return bracketing the handler, which are plausibly the dominant term and which
these instruments cannot see. Even at 3 µs of unmeasured kernel cost per fault,
the total would be about 1.2 s in 100 s — roughly 1%, material but modest.

So the honest position is: **this change is justified as correctness, not
performance.** It removes an undocumented dependency on Wine having established
x18 before every entry into FEX — a contract that is real, unwritten, and would
break silently. The absorb count falling by five orders of magnitude is the
evidence the dependency was there, not evidence that removing it was fast.

Result 17 reasoned from a small count to "immaterial" and was wrong at title
scale. The opposite error was equally available here: reasoning from 400,000 to
"must fix" without ever pricing it. Both are the same mistake.

## 5. Regression

31/31 against the isolated census runtime, FEX `5944be0`, wine `54048cb`.

One process note. The first corpus run failed `seh_nullcall` and
`nullcall_probe` at exit 5, which looked like this change regressing #20. It was
not: this branch was cut from `98d5e2d`, which predates #20's fix, so those
tests failed exactly as they did before #20 landed. Rebasing onto
`alloy/task-20-null-call` and rebuilding returned 31/31. A branch cut from the
wrong base produces failures indistinguishable from a regression, and the only
way to tell is to check what the build actually contains.

## 6. What is not done

- The residual 8 absorbs at offset 0x30 are unattributed. They are ~0.002% of
  the original volume, so nothing here argues for chasing them.
- The kernel-side cost of a fault is unmeasured, so the true saving is bounded
  below by 6.9 ms per boot and not bounded above.
- Only one title. The absorb volume is a property of the workload, and a
  36-thread Unity/Mono boot is one point.

## Doctrine reinforced

Result 17's lesson was that a rate-limited counter is not a count. This one adds:
**a measurement that disproves a hypothesis has only disproved the thing it
actually measured.** Result 17 changed `Module.S`, measured no effect, and
concluded the *class* of defect did not exist. What it had shown was narrower —
that those particular instructions were not the faulting ones — and result 17
even recorded the evidence (x8/x10/x11, not x16/x17) that a second copy existed.
The inference outran the measurement by exactly one copy.
