# WINE-001 result 10 — translated writes between separate Darwin MAP_JIT views: the emulation lands, but the prototype's rejections were livelocks, its fault address was wrong, and its decoder was tested in duplicate

**Author:** Tim Isaev
**Date:** 25 July 2026
**Wine:** `alloy/spike-wine-001` @ `8d5974a` (on the prototype `de36e21`) ·
**FEX:** `libarm64ecfex.dll` SHA-256 `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6`
(the `build-task6` binary; it predates FEX `98d5e2d`, the MXCSR work landed by #32, which was
not rebuilt during this task — every run below used this one binary, verified unchanged
before and after) · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

Issue #30 asked for a regression fixture and rejection coverage around the
prototype that unblocked #10. The prototype's emulation is correct and is kept
as-is. Everything the issue asked to *prove*, once actually executed, found
something:

- **The fixture reproduces the livelock**: 9.5 million resolve/re-fault cycles
  in 30 s at one fixed pc and one fixed target, zero progress (§1). With the
  fix it passes, verifying exact bytes across scalar, vector, atomic and
  four-thread cases.
- **Every rejection path in the prototype was itself a livelock** (§2). The
  ordinary fault path cannot terminate these faults, so returning "not mine"
  is an infinite loop, not a refusal. Three of the four rejection modes the
  issue asked for could not have passed as written.
- **The reported fault address was wrong**, and that is why the corrected
  rejection still could not reach the guest (§3). FEX reads a write fault on
  an executable page as self-modifying code and retries it; naming the byte
  that actually cannot be written both matches hardware and lets the exception
  through.
- **The decoder existed twice and the copies had already diverged** (§4). The
  unit test exercised a replica whose scaled `uimm12` offset was narrowed to
  `int16_t`; the shipped decoder's was not. The test could not have caught it.
- **One rejection case is unreachable from guest code** and is now covered by
  the decoder unit test instead, for a stated reason (§5).
- Full regression sweep green, including the entitled title's headless and
  graphical boots and the exact-policy DXMT D3D11 smoke (§6).

## 1. The fixture, and what it measures

`spikes/WINE-001/testcases/jit_cross_view.c` allocates guest code and a store
target as two separate `PAGE_EXECUTE_READWRITE` views, so the guest's
translated code and its target land in different Darwin MAP_JIT mappings.
Against the pre-fix runtime, `positive` never returns:

```text
segv heartbeat #9500000 status 00000000 addr 0x107b446f0 pc 0x107b446f0
resolved-fault heartbeat #9500000 addr 0x109070030 pc 0x107b446f0
```

Same pc, same target address, ~316,000 faults per second, alternating
"faulted" and "resolved" — the write switch flipping between the position the
store needs and the position the translated block needs to execute. Exit 124
(timeout), no output at all. With the fix the same binary prints
`PASS JIT_CROSS_VIEW positive exact-bytes scalar vector atomic threads`.

The fixture is title-agnostic: it needs no game, no Unity and no Mono, only
two JIT views on one thread.

## 2. Rejecting a fault is not the same as declining it

`virtual_handle_fault` resolves a write fault on a `VPROT_JIT` view by calling
`pthread_jit_write_protect_np(0)` and returning `STATUS_SUCCESS`, after looking
up the view for **the first byte alone** (`find_view(addr, 1)`). That is right
when native code writes a JIT page. It cannot terminate when the storing
instruction is itself in a MAP_JIT view, because executing that instruction
needs the opposite position of the same per-thread switch. So:

> write fault + storing code is executable MAP_JIT + target's first page is a
> Wine JIT view ⇒ the ordinary path provably cannot make progress.

The prototype returned `FALSE` on all five of its rejection paths, which under
that condition is an unkillable spin rather than a refusal. Measured, not
inferred: `decommitted-crossing` hung with the prototype in place, at the same
heartbeat signature as §1.

`virtual_is_jit_write_pair` is therefore replaced by
`virtual_classify_jit_write`, returning `JIT_WRITE_NOT_OURS` /
`JIT_WRITE_WOULD_SPIN` / `JIT_WRITE_OK`, and the handler returns
`JIT_STORE_PASS` / `JIT_STORE_EMULATED` / `JIT_STORE_RAISE`. Once the
classifier reports anything but `NOT_OURS`, no path may fall through: the
handler either emulates the store or raises an access violation. A diagnosable
crash beats a hang — the livelock this handler exists to remove is precisely
what made the underlying defect expensive to find in the first place.

The range check also now looks the view up per page rather than once for the
whole range, so a store leaving its view is reported where it leaves rather
than rejected wholesale with no usable address.

## 3. The fault address was naming a writable byte

Raising the access violation was not enough. It was raised 1.7 million times
in 25 s and never reached the guest. FEX's own log said why:

```text
D 2C Exception: Code: C0000005 Address: 105AA78DC
D 2C Handled self-modifying code: pc: 105AA78DC fault: 106FF0FF8
```

FEX sees a write fault on an **executable** guest page, classifies it as the
guest modifying its own code, invalidates its translation cache and resumes at
the same instruction. An access violation reported at an address inside a
valid RWX page can never be delivered — it will always be absorbed.

The prototype reported `si_addr`, the start of the store. For a 16-byte store
at `page_end - 8` that address is in the *committed* page and is perfectly
writable; the byte that cannot be written is in the next page. Hardware
reports the first inaccessible byte. Reporting it too is both the correct
semantics and, because that page is not executable, outside FEX's
self-modifying-code claim:

| | prototype | fixed |
| --- | --- | --- |
| reported address | `0x109680FF8` (writable) | `0x109681000` (decommitted page) |
| delivered to guest | never | caught by `__except` |
| outcome | livelock | `EXCEPTION_ACCESS_VIOLATION` |

The `unwritable` warning also gained a heartbeat. Capped at the first 8 it
reported "8" for both a handful of events and for 1.7 million, which is
exactly how the raise-and-refault loop stayed invisible — the same instrument
failure as CPU-001 result 17, in new code.

## 4. The decoder was tested in duplicate, and the duplicates disagreed

The prototype inlined the decode logic in `signal_arm64.c`. Beside the test
sat `spikes/WINE-001/jit-store/arm64-jit-store.h`, a second, separately
written decoder, described in the test as "the production decoder". It was
not. The two had already diverged on day one:

```c
int16_t address_offset;                                /* the copy */
store->address_offset = ((instr >> 10) & 0xfff) * 16;  /* max 65520 */
```

A scaled `uimm12` reaches `4095 * 16 = 65520`, so every `str Qt` offset above
32767 wrapped negative and addressed the wrong page. The shipped code computed
the same quantity in `ULONG_PTR` and was correct. The test exercised offset
272 only, so it would never have noticed; a green suite would have reported
confidence it had not earned.

The decoder now lives in the Wine tree at `dlls/ntdll/unix/arm64_jit_store.h`,
the signal handler uses it, and `run-decode-test.sh` compiles the test against
that header by `-I` — a copy is impossible by construction. Control run:
reintroducing `int16_t` fails the build under `-Werror`
(`-Wtautological-constant-out-of-range-compare`), so the test demonstrably
detects the defect rather than merely passing.

## 5. One rejection case cannot be reached from guest x64, and says so

`unsupported` intended to prove that unknown store forms fall through. It
used `movntdq`, and it failed — because FEX lowers `movntdq` to an ordinary
`str q`, a *supported* form, which was correctly emulated:

```text
trace:seh:handle_arm64ec_jit_store emulated translated 16-byte unsigned-offset
store into guest JIT page 0x1050a0000
```

The premise was wrong, not the code. Producing a store form the decoder does
not know would test which ARM64 instructions FEX selects, not what this
handler accepts, and would break whenever FEX's instruction selection changes.
Unknown-form rejection therefore belongs in the decoder unit test, where it is
deterministic — 12 rejected encodings, including `stnp`, `st1`, pre-index and
register-offset forms. The guest mode is retained as `non-temporal`, asserting
the store *succeeds* with exact bytes, which is what it actually establishes.

`rx-after-rwx` is also unreachable: `VirtualProtect` down to
`PAGE_EXECUTE_READ` on a JIT view is refused by this fork with
`ERROR_ACCESS_DENIED`. Its coverage — view still JIT, page no longer usable —
is reached instead by decommitting the page (`decommitted-target`).

The rejection modes now assert with `__try/__except` on
`EXCEPTION_ACCESS_VIOLATION` at the expected address, rather than by the
process failing to print. "Did not return" is satisfied equally by a correct
rejection, a livelock and a crash in startup; it cannot distinguish the two
outcomes this change is about.

## 6. Regression evidence

All against `8d5974a`, FEX `ef4ce1be`.

| Suite | Result |
| --- | --- |
| CPU-001 plain corpus (15 tests) | green |
| `seh_multi` × 5 shapes, `seh_repeat` × 3 shapes | green |
| `x64hello` loader smoke | green |
| `jit_cross_view` × 5 modes | green |
| decoder unit test (+ failure control) | green |
| `seh_nullcall` | **fails, exit 5 — pre-existing, issue #20** |

`seh_nullcall` is an instruction-fetch abort (`esr_ec 0x20`); this handler only
engages on data-abort writes, and its log contains zero JIT-store diagnostics.
Issue #20 records the same exit 5 before this change.

Entitled title, build 24280929, exe SHA-256
`1fb707b1…f95455`, all four DXMT inputs hash-identical to the STORE-001
result 02 record:

| Check | Result |
| --- | --- |
| exact-policy selection | `sir-brante-24280929`, `graphics dxmt`, `default 0`, before imports |
| headless boot | Unity 2018.3.0f2, Mono reload, `GameManager (SetScreenMode)`, asset load/unload passes |
| graphical boot | additionally `Direct3D 11.0 [level 11.1]`, exit 0 |
| livelock heartbeats | 0 in both runs |
| exact-policy DXMT D3D11 smoke | `d3d11-smoke` / dxmt selected, native DXMT `d3d11.dll` loaded, Apple M2 Pro, readback `b=191 g=128 r=64 a=255` |

The D3D11 smoke binary is byte-identical to the one in result 02
(`abaf8570…4b8efb`).

Two caveats on the numbers above. The runtime logs default to
`-all,+alloy,+loaddll`, so the handler's own counters read zero in them; that
is the log filter, not an absence of emulation, and it is not quoted as
evidence here. The GFX-001 DXMT install in the tree still symlinks
`Developer/macgaming`, a path that has not existed since the repository
rename, so a fresh install wired to this build was used for the smoke.

## 7. Disposition for #30

All acceptance criteria are met, three of them only after the defects above
were fixed:

- generic regression fixture with separate MAP_JIT views, previously
  livelocking, now verifying exact written bytes — **met** (§1);
- rejection of non-MAP_JIT code, non-JIT targets, ranges crossing an invalid
  page and mismatched fault addresses — **met, and now actually terminating**
  (§2, §3); unsupported opcodes — **met in the decoder unit test**, with §5
  recording why the guest-side form was withdrawn;
- diagnostics bounded and signal-handler-safe — **met**, with a heartbeat
  added so bounded no longer means unreadable (§3);
- x64 ISA, memory-ordering, TLS/thread, SEH/unwind regressions — **met** (§6);
- exact-policy DXMT D3D11 smoke and the build-24280929 headless and graphical
  boot checks — **met** (§6).

Follow-ups worth their own issues, none blocking: `VirtualProtect` on a JIT
view is refused (§5), and the GFX-001 DXMT install still points at the
pre-rename path (§6).

## Doctrine reinforced

Three separate instruments lied in one task, and each was caught only by
insisting the instrument report the quantity claimed. The rejection paths
reported "refused" while looping; the fault address reported a byte that was
writable; the unit test reported a decoder it did not test. Result 17 drew
this lesson from a rate-limited counter — here the same first-N cap hid a
1.7-million-iteration loop *in code written to fix a loop*. The general form:
a test, a counter or a returned status is evidence only after you have made it
fail on purpose.
