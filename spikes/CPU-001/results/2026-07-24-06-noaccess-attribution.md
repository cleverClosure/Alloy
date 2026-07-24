# CPU-001 result 06 — noaccess shear attributed: Wine stacks healthy, all three sources are FEX guard mechanisms

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `61bf569` · **FEX:** 0589d9b (darwin-teb build) ·
**Hardware:** MacBook Pro M2 Pro, 16 GB, macOS 26.5

Result 05 attributed two of the three baseline noaccess-class census events to Wine's
thread-stack barriers and recommended a fork patch to host-align them. A guest-side probe
(`testcases/noaccess_inventory.c`) shows that attribution was **wrong**, and the corrected
picture is more consequential: every committed-NOACCESS shear event belongs to FEX, and each
one is a **fault-dependent mechanism that shear silently disables**.

## Correction: Wine thread stacks are already host-page-aligned and enforced

The probe walks its own stacks from `TEB->DeallocationStack` (main thread and a fresh
`CreateThread` worker, identical layout):

```text
region base+0x0000 +0x4000 state=MEM_RESERVE            <- hard barrier, 16 KB, uncommitted
region base+0x4000 +0x4000 state=COMMIT protect=RW|GUARD <- guard region, 16 KB
region base+0x8000 +0xf8000 state=COMMIT protect=RW      <- stack
stack barrier read: faulted (c0000005)
```

Barrier and guard are host-page-sized and host-page-aligned (`virtual_alloc_thread_stack`
works in `host_page_size` units upstream), and the barrier read genuinely faults. **The
result-05 recommendation to patch Wine stack layout is withdrawn — there is nothing to
fix.** Result 05's `[23 23 23 20]` events were not stacks.

## The real owners: three FEX guard mechanisms, all fault-dependent, all shear-disabled

**1. JIT temp-buffer overflow guard — the serious one.**
`FEXCore/Source/Interface/Core/JIT/JIT.cpp:866`: translated code is emitted into a temp
buffer whose **last 4 KB page is the overflow detector** (`ThreadState->JITGuardPage`).
Writing past `UsableBufferRange` is designed to fault into
`Windows/Common/JITGuardPage.h` → long-jump restart with `NeedsLargerJITSpace` → re-emit
with a larger buffer. WINEDEBUG traces confirm the probe's mystery allocations are exactly
these buffers (16 KB and 40 KB: `AlignUp(2·4K + SSACount·multiplier)`): committed RW, then
the last page flipped NOACCESS — census pattern `[23 23 23 20]`. Under shear the guard
write **silently succeeds**: the emitter overruns its buffer without triggering the resize
path, and with `MEM_TOP_DOWN` packing allocations adjacently, a large-enough block can run
into a neighboring allocation. This mechanism is hot on real workloads (any block whose
size estimate is exceeded), not a rare path.

**2. Call-ret stack imbalance guards — invisible to the committed-only census.**
`Source/Windows/Common/CallRetStack.h`: a 4 MB per-thread call-ret stack
(`CALLRET_STACK_SIZE = 0x400000`) with one **reserved** 4 KB guard page on each side;
`HandleAccessViolation` re-centers `callret_sp` on the expected fault. Both guards shear
(base guard shares its host page with the first three RW pages; top guard with the last RW
page), so imbalance is never detected and a drifting `callret_sp` eventually walks out of
the allocation entirely. Reserved-NOACCESS carries vprot `0x00`, so these never appear in
the census noaccess class — the census undercounts by design; the probe's passive walk
missed them too (committed-only filter). Both instruments now have a documented blind spot
for reserved guards.

**3. Code-cache chunk tail guard.**
The probe's `alloc+0xFFF000` NOACCESS page inside a ~16 MB RWX region is the code-cache
tail guard from result 05 (`[27 27 27 20]`), same class, lower severity.

Wine's own EC machinery allocates no NOACCESS pages at all
(`grep PAGE_NOACCESS` over `signal_arm64ec.c` and unix thread/virtual paths: none outside
the documented stack layout).

## Census baseline, reinterpreted

The constant "noaccess-class 3" across every corpus run = two JIT temp-buffer guards plus
one cache tail guard — **zero Wine-owned, zero app-created**. The clean-state target after
the FEX fix is noaccess-class 0 (plus deliberate test pages).

## Founder handoff (all FEX-tree, no-AI boundary)

Single root cause: `FEXCore/include/FEXCore/Utils/TypeDefines.h:9` hardcodes
`FEX_PAGE_SIZE = 4096`, and every guard derives its size and placement from it. On a 16 KB
host the guard spans must become host-page-sized **and** host-page-aligned. Sites:

1. `JIT.cpp` temp-buffer carve-out (`UsableBufferRange`, `JITGuardPage`) — guard span =
   host page, buffer sized so the guard starts host-aligned.
2. `CallRetStack.h` — both guards host-page-sized; keep `CallRetStackBase` host-aligned so
   the RW span doesn't share host pages with either guard.
3. Code-cache chunk tail guard — same treatment.

Verification is already in place: corpus + census rerun should show noaccess-class 3 → 0,
and `noaccess_inventory.exe` should list no FEX-owned committed-NOACCESS regions.

## Probe hazard worth remembering

The first inventory build probe-read every foreign inaccessible region it found and
**hung the process** — touching FEX-internal guard/redzone pages from guest code lands in
emulator fault handling that is not re-entrant for this purpose. The committed probe is
passive (list only) and probe-reads nothing but its own stack barrier. Treat FEX-owned
inaccessible regions as do-not-touch from diagnostics.

## Standing state after this result

- Wine fork: no changes needed this round; census stays as the standing instrument
  (noaccess class now has a precise expected value: 0 after the FEX fix).
- The only unowned shear exposure remains app-created interior NOACCESS, measurable for
  free by the census once Steam/portfolio titles run (STORE-001, gate 5).
- Watch item continuity: the per-thread absorbed AV at FEX DLL+0x1018 (result 04) targets
  the same high-VA neighborhood as the JIT temp buffers; plausibly the emitter probing its
  own guard — founder can confirm while fixing (1).
