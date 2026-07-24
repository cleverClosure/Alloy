# CPU-001 result 09 — FEX guard granularity fixed and directly validated; result 06's census attribution corrected

**Author:** Tim Isaev
**Date:** 24 July 2026
**FEX:** `alloy/spike-fex-001` @ `635922c` (fork base 0589d9b) · **Wine:**
`alloy/spike-wine-001` @ `87adaaa` · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

The three FEX guard mechanisms result 06 identified are now armed at host-page
granularity, and the fix is **proven by direct experiment** — not by the census metric
result 06 proposed, which turned out to measure the wrong thing.

## The fix (fork `635922c`)

A new `FEX_GUARD_PAGE_SIZE`, selected at build time by `-DFEX_HOST_GUARD_PAGE_SIZE`
(16384 in the darwin-teb configuration), replaces `FEX_PAGE_SIZE` for the size,
alignment, usable-range, and handler bounds of every guard region:

- JIT temp-buffer overflow guard (`ThreadPoolAllocator.h` alloc, `JIT.cpp` sizing,
  `JITGuardPage.h` handler range).
- Code-buffer tail guard (`SharedCodeBufferManager.{h,cpp}`, `CPUBackend.cpp` range
  check) — the arming site in `CodeBuffer::CodeBuffer` was the one initially missed.
- Call-ret stack guards on both sides (`CallRetStack.h`).

A `static_assert` requires the guard to be a whole multiple of the FEX page.
`__APPLE__` is undefined for the ARM64EC Windows PE target, so the host-page size is a
build property, not a compile-time platform check — hence the flag.

## Direct validation — `testcases/guard_enforce.c`

The verification does not rely on any FEX internal. It tests the one physical claim the
whole fix rests on, over the same `NtProtectVirtualMemory` path FEX guards use, and
detects the fault by **child-process exit code** (not in-process SEH — see the dispatch
caveat below):

```text
case A (4KB guard on shared host page): child exit 0x00000000 -> survived (UNENFORCED - shear)
case B (full 16KB host-page guard):     child exit 0xC0000005 -> FAULTED (enforced)
result: 4KB guard unenforceable, 16KB guard enforceable - FEX fix validated
```

A 4 KB `PAGE_NOACCESS` on a committed 16 KB host page is silently unenforced — the write
lands in the accessible remainder of the host page and the permissive vprot union keeps
the whole host page writable. A full 16 KB guard raises `STATUS_ACCESS_VIOLATION`. This
is exactly FEX's old-vs-new guard behavior: **the old 4 KB guards were unenforceable
here; the new host-page guards are enforceable.** Regression-neutral throughout — full
CPU corpus green (`x64hello`, `isa_smoke`, `memory_semantics`, `exception_unwind`,
`win_smoke` all exit 0) and the D3D11 triangle+texture test still pixel-exact.

## Correction to result 06

Result 06 predicted the shear census would drop from 3 noaccess events to 0. It did
**not** move — byte-identical across every rebuild, including one that provably resized
the code-cache guard. Decoding the census vprot bytes against Wine's own definitions
(`VPROT_READ 0x01 … GUARD 0x10 COMMITTED 0x20`):

- `[27 27 27 20]` = three RWX-committed pages + one committed-NOACCESS page.
- `[23 23 23 20]` = three RW-committed + one committed-NOACCESS.
- `[23 20 00 00]` = one RW-committed, one committed-NOACCESS, two reserved.

All three are tagged **`view map`** (mapped sections). FEX's guard buffers are anonymous
`VirtualAlloc` — **`view none`**. They are different memory; a correctly host-page-sized
FEX guard produces a *uniform* NOACCESS host page that the mixed-only census never
flags, so the census could never have shown "3 → 0". **Result 06's finding (FEX 4 KB
guards unenforced) was correct; its verification metric was mis-attributed** to Wine-side
mapped-section guard pages. Likewise `jit_pages` (still exit 7) tests a *guest*
protecting a 4 KB page — that is Wine's sub-host-page handling, never a FEX-guard signal.
The lesson: verify a mechanism by exercising the mechanism (guard_enforce.c), not by a
proxy metric whose provenance was assumed.

## Second finding: exception dispatch blocks in-process fault verification

The first version of guard_enforce.c caught the guard fault with `__try/__except` and
**wedged** on case B — the exact multi-/single-thread exception-dispatch deadlock of
result 08 (the caught hardware fault never returns through dispatch). Rewriting to
child-process exit-code detection sidestepped it. A useful refinement of result 08:
**unhandled** single-threaded AVs terminate cleanly with the exception code (`0xC0000005`,
winedbg auto-launch disabled); it is specifically **caught** hardware faults whose
in-process dispatch is unreliable. Item #1 of the founder list was gated behind item #2
until the verification was restructured to avoid SEH.

## Founder note

This fix is founder-owned FEX-tree work; per the session decision it was implemented
AI-assisted on the fork-local branch `alloy/spike-fex-001` (policy exception and
provenance recorded in that tree's `CLAUDE.md` / `PROVENANCE-ALLOY.md`) and is not
eligible for upstream contribution without independent reimplementation.
