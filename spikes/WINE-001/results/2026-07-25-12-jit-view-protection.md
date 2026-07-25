# WINE-001 result 12 — a Darwin JIT view's protection can be narrowed on paper and never in hardware

**Author:** Tim Isaev
**Date:** 25 July 2026
**Wine:** `alloy/task-34-jit-view-protect` @ `372f8e6` (on `54048cb`) ·
**Hardware:** M2 Pro, 12 cores, 16 GB, macOS 26.5.2 (`25F84`)

## Outcome

Issue #34 asked whether a guest can narrow a JIT view's protection the way it
can on Windows, and if not, whether the right answer is to report success and
enforce nothing or to keep failing.

- **The host cannot do it, and not only for narrowing** (§1). Darwin refuses
  `mprotect` outright on a `MAP_JIT` mapping created write+exec — including
  re-setting the protection it already has.
- **Reporting success is the better of the two available answers** (§2), and is
  what landed. `VirtualProtect` now succeeds and `VirtualQuery` agrees.
- **It is reported, not enforced** (§3). The page stays writable and a store to
  it is not refused. That is a real weakening against Windows and is asserted
  by the fixture rather than left as a comment.

## 1. What Darwin actually allows

A native probe, with an ordinary mapping as the control so the result is not
just "everything fails here":

| Mapping | Transition | Result |
| --- | --- | --- |
| `MAP_ANON`, created RW | RW → R | **OK** |
| `MAP_ANON`, created RW | R → RW | **OK** |
| `MAP_ANON`, created RW | RW → NONE (one page) | **OK** |
| `MAP_JIT`, created RWX | RWX → RWX (no-op) | `EACCES` |
| `MAP_JIT`, created RWX | RWX → RX | `EACCES` |
| `MAP_JIT`, created RWX | RWX → RW | `EACCES` |
| `MAP_JIT`, created RX | RX → RX (no-op) | **OK** |
| `MAP_JIT`, created RX | RX → RWX | **OK** |
| `MAP_JIT`, created RX | RX → R | `EACCES` |

Two things fall out. A `MAP_JIT` mapping created write+exec is **frozen**: even
a no-op `mprotect` is refused. And protection on a `MAP_JIT` mapping can be
widened toward RWX but never narrowed.

Wine maps `MAP_JIT` exactly when a view is exec+write
(`virtual.c`, `map_view`), so **every JIT view is in the frozen case**. There
is no sequence of host calls that narrows one.

## 2. What changed

`set_vprot` had already written the new page vprot before `mprotect_range`
failed, so the old behaviour reported `ERROR_ACCESS_DENIED` against bookkeeping
that had changed anyway — the worst of both. On a `VPROT_JIT` view the
bookkeeping is now kept and success reported.

Both fault paths were absorbing writes to a JIT view unconditionally, which
would have made the new bookkeeping meaningless:

- `virtual_handle_fault` dropped the thread's write protection for **any**
  write fault on a JIT view. It now requires `VPROT_WRITE` on the page first.
- the kernel-JIT arm of `virtual_classify_jit_write` required the page to be
  committed and executable but not writable, so a narrowed page still looked
  emulable. It now requires `VPROT_WRITE` too, matching the arm beside it.

Neither changes behaviour for a page that is still writable, which is every
page of a view no guest has narrowed.

## 3. The limitation, stated plainly

```text
guest page size 4096
rwx view at 0000000103410000
VirtualProtect RWX->RX ok (old=0x40)
VirtualQuery protect=0x20
plain store to the narrowed page...
  NO FAULT: page still writable, value=0x22
```

The guest asks for `PAGE_EXECUTE_READ`, is told it got it, `VirtualQuery`
confirms it, and the page is still writable. Tested both with and without a
write before the narrowing, in case an absorbed write had left the thread's JIT
write switch open; it makes no difference.

So this is not "enforcement that occasionally misses". There is no enforcement.
A guest JIT that hardens its pages to catch its own stray writes will not catch
them here.

The alternative was to keep failing, which is honest but breaks a pattern that
works on Windows for a protection Darwin was never going to provide. Reporting
success is chosen because the failure mode is narrower: a guest that hardens
pages defensively keeps running, and one that *relies* on the fault to be
correct is a case we have not seen and would be broken by the old behaviour
too.

## 4. Fixture

`jit_cross_view` regains `rx-after-rwx`, the mode #30 had to drop when the
narrowing could not be reached from guest code. It no longer asserts a fault —
that would assert something untrue — but pins the whole observable shape:
`VirtualProtect` succeeds, reports the correct old protection, `VirtualQuery`
agrees, and the store is not refused. If Darwin ever allows the `mprotect`, or
the runtime gains a way to enforce the narrowing, the mode fails and whoever
sees it is pointed at this note.

All six modes pass:

```text
positive              PASS exact-bytes scalar vector atomic threads
rx-target             PASS rejected with an access violation
rx-after-rwx          PASS narrowing reported, not enforced (Darwin MAP_JIT)
decommitted-target    PASS rejected with an access violation
decommitted-crossing  PASS rejected with an access violation
non-temporal          PASS exact-bytes
```

`decommitted-target` is kept: it reaches the same per-page arm without
depending on the narrowing being honoured, so the two modes fail independently.

## 5. Regression

The full CPU-001 guest corpus was run against the modified `virtual.c`. Every
exit matches the pre-change baseline, including the memory-shaped guests that
would notice a protection-bookkeeping mistake — `jit_pages`,
`memory_semantics`, `noaccess_inventory`, `guard_enforce` — and the SEH and
threading families.
