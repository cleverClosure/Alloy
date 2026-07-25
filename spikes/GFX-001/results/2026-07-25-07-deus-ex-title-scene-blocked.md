# GFX-001 result 07 — second D3D11 title blocked before first present: Deus Ex: Mankind Divided

**Author:** Tim Isaev

**Date:** 25 July 2026

**Disposition:** title 2 of 2 not measured. The title does not reach a scene: it
dies during startup in Wine's ARM64EC delay-import path, before creating any
D3D11 work. Issue #11 and E3 stay open. No graphics claim is made or withdrawn.

## Claim boundary

This result reports a **blocker**, not a measurement. Nothing here says anything
about how Alloy renders Deus Ex: Mankind Divided, because the title never
renders a frame. The one thing it does establish is *where* the runtime fails
and that the failure is not in the graphics stack: the crash is in `rpcrt4`
during service-manager setup, with `d3d11.dll`, `dxgi.dll` and `winemetal.dll`
loaded but never exercised. DXMT wrote no metrics file on any run.

[Result 06](2026-07-25-06-sir-brante-title-scene.md) remains the only measured
entitled title. Its verdict is unchanged.

## Exact input and host

| Input | Value |
| --- | --- |
| Title | Deus Ex: Mankind Divided (GOG `gameId 1296690054`), game build `v1.19 build 801.0` |
| Store build | GOG build `53307442018838439` |
| Game executable SHA-256 | `cf4805608f9cc7129a8f04ade8eeefdf1f0cd849a1f702dfe8f0cd06f2f53ee8` |
| Wine | `54048cbd2bf69aee8cc7be2beb14c5ab63a17842` |
| DXMT | `e520fea415ba4b82b0c346dae77bbb1be4897453` plus the tracked D3D11-only instrumentation patch |
| FEX ARM64EC DLL SHA-256 | `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` |
| Host | MacBook Pro (M2 Pro, 12 cores, 16 GB), macOS 26.5.2 (`25F84`) |

Result 06 measured Sir Brante at Wine `8d5974ac`. This run is two commits later
(`de36e21`→`8d5974a`→`54048cb`); the blocker reproduces identically on both, so
the difference is not load-bearing here. It would have to be reconciled before
the two titles are reported as one measurement set.

Full input record:
[`data/issue-11/deus-ex-blocked-run.json`](data/issue-11/deus-ex-blocked-run.json).

## Harness

[`launch-deus-ex-mankind-divided.sh`](../../STORE-001/runtime-launch/launch-deus-ex-mankind-divided.sh)
mirrors the Sir Brante launch path: policy compiled before the first Wine
process and handed to every Wine utility on descriptor 9, per-process DXMT
routing keyed on the entitled `DXMD.exe` image hash, deterministic UTC and a
1280×720 windowed `EnableDX12=0` graphics seed, an isolated prefix under
`spikes/STORE-001/work/`, and per-run metric and shader-cache paths constrained
to that work root. The scene it targets is the title's own `-benchmark` mode.

The harness itself is sound: the policy layer selects
`dxmd-gog-53307442018838439 graphics dxmt` for the game image and
`unknown-restricted` for everything else, and the game's own graphics DLLs load
from the DXMT provider directory. The original CrossOver bottle and its running
process were never modified or stopped.

## Observed failure

The title logs its own startup and its own crash:

```text
[NxApp] PreInit
[Steam] Initializing.
   ... 15.4 s ...
[Crash] Unhandled exception at address 0x00000000fe934aac (code: 0xc0000005): "Access violation"
```

Five runs, five identical crashes: four on 25 July at 11:27, 11:31, 11:48 and
11:52 UTC, and one at 13:11 UTC after Wine's `ntdll` was rebuilt. Each wrote a
minidump next to the title's log. No run produced a `Present`.

`0xfe934aac` is the low half of `0x6ffffe934aac`, which is `rpcrt4.dll + 0x64aac`
in that run. Against the ARM64EC `rpcrt4.dll` from the same build:

| Address | Symbol | Source |
| --- | --- | --- |
| RVA `0x64aac` (faulting) | `NdrContextHandleUnmarshall` | `dlls/rpcrt4/ndr_marshall.c:7024` |
| RVA `0x72850` (caller) | `client_do_args` | `dlls/rpcrt4/ndr_stubless.c:529` |

The fault is a **write to address `0x10`** (`type 1`, `esr_ec 0x24`,
`dfsc 0x6`).

## What the RPC trace shows

The failing call has five parameters — in-unique-wstring, in-unique-wstring,
in-DWORD, out `FC_BIND_CONTEXT` simple-ref, out-DWORD return — which is
`ROpenSCManagerW`. The server side completes normally: it allocates a context
handle and replies. The client side then unmarshals into the caller's `[out]`
pointer, with context-handle flags `0xa0` (`VIA_PTR|IS_OUT`), so
`NdrContextHandleUnmarshall` runs `*ccontext = NULL` through that pointer.

The pointer it was given is `0x10`:

| Parameter | Expected | Seen by the stub |
| --- | --- | --- |
| 0 | `NULL` machine name | `0x0` |
| 1 | `NULL` database name | `0x0` |
| 2 | access mask | `0x1c36f040` |
| 3 | `&SC_HANDLE` | `0x10` |
| 4 | return value | `0x0` |

The first two arrive correctly and the rest do not, and `0x1c36f040` is the low
half of a stack address rather than an access mask. **The arguments passed in
registers survive; the arguments passed in memory do not.**

## Why: variadic delay import through ARM64EC

`sechost.dll` implements `OpenSCManagerW` and **delay-imports** `rpcrt4.dll`,
`NdrClientCall2` among them (`llvm-readobj --coff-imports`). `NdrClientCall2` is
variadic, and its ARM64EC definition
(`dlls/rpcrt4/ndr_stubless.c:1011`) is naked assembly that depends on the
ARM64EC variadic contract — `x4` pointing at the x64-shaped stack argument
block:

```asm
stp x2, x3, [x4, #-0x10]!   /* fold the register varargs onto the block */
mov x2, x4                  /* ... and take that as stack_top */
```

The pieces that are verified:

- `sechost`'s own call stub is
  `adrp x16, __hybrid_auxiliary_delayload_iat; ldr x16, [x16, #0x58]; br x16` —
  it forwards `x0`–`x5` untouched.
- Wine's `arm64x_check_call` (`dlls/ntdll/signal_arm64ec.c`) uses only `x9`,
  `x16` and `x17`, so it preserves the argument registers.
- On the **first** call that auxiliary slot still holds the `__impchk_` thunk,
  which loads the regular delay IAT — still the x64 delay stub. The call is
  therefore routed to `#NdrClientCall2$exit_thunk`, whose body is
  `$iexit_thunk$cdecl$i8$varargs`: it saves `x4`/`x5` and calls
  `__os_arm64x_dispatch_call_no_redirect`.
- Alloy points that dispatcher at FEX
  (`fex_dispatch_call_no_redirect_wrapper`), so the x64-side frame is built
  inside the emulator.
- What arrives in `rpcrt4` carries only the register arguments.

A probe on `x4`/`x5` at the ARM64EC entry, added after this result's first
draft, settles which side drops the block. On the failing call:

```text
main: 0 0 0x109C8FDA0 0x10 0x109C8FE08
varargs x4 0x109C8FD80 x5 0 (expected x4 0x109C8FD80)
varargs block: 0x109C8FDA0 0x10
```

`x4` is exactly right. `x5` is 0, and the memory `x4` points at holds
`(0x109C8FDA0, 0x10)` — the pointer-and-size pair the exit thunk staged with
`stp x4, x5, [sp, #0x20]`, read back as if it were the two real stack
arguments. `0x10` is the byte count of the two arguments that should have been
copied, and it is the same `0x10` that becomes the `[out]` context-handle
pointer.

So the exit thunk does its job; nothing expands the staged block on the way
back in. The entry thunk sets `x4 = rsp+0x20` and, having no way to know a size
it was never given, `x5 = 0`. Neither a generic dispatcher nor an entry thunk
can recover this, so the fix is to stop the first call from making the round
trip at all.

The partial Wine change carried in
[`../instrumentation/0002-arm64ec-delayload-aux-iat.patch`](../instrumentation/0002-arm64ec-delayload-aux-iat.patch)
snaps the auxiliary delay-load IAT to the callee's ARM64EC entry once the
import resolves. It works — the run shows seven fast-forward events, three of
them `sechost`→`rpcrt4`, one landing on `rpcrt4` RVA `0x73f14`, which is exactly
the ARM64EC `NdrClientCall2` — but it cannot help the first call, which has
already lost its arguments by the time the resolver runs. Every later call would
be correct; the title never gets a later call.

## Reproducer

[`spikes/WINE-001/testcases/ec_delay_import.c`](../../WINE-001/testcases/ec_delay_import.c)
is a 30-line x64 guest that calls `OpenSCManagerW` once behind a vectored
handler. It fails at the same address as the title:

```text
start
veh installed
FAIL raised 0xc0000005 at 00006FFFFE934AAC
```

Exit 3, twice in a row. A fixed runtime prints `PASS` and exits 0, so this
doubles as the regression gate.

One incidental finding while building it, recorded because it will waste
someone's afternoon otherwise: a **byte-identical** binary reproduces the fault
as `ec_delay_import.exe` and instead raises `STATUS_ILLEGAL_INSTRUCTION` before
`main` (exit 29) as `arm64ec_delay_import.exe`. The threshold is between a
15- and a 20-character image stem; `WIN32_LEAN_AND_MEAN` or
`-Xclang -fasync-exceptions` trigger the same masking failure. That is a
separate emulator defect and is not analysed here.

## Verdict

**Blocked, not failed.** Alloy's graphics stack is not implicated: the title
dies in the ARM64EC delay-import path during service-manager setup, roughly
15 seconds into startup and before any D3D11 device work. E3 still has exactly
one measured title.

Two things must happen before #11 can close, and they are independent:

1. The variadic delay-import defect is tracked as #11's blocker in issue #59,
   with the reproducer above as its regression gate. Failing that, a second
   D3D11 title that does not touch `OpenSCManagerW` must be installed — only
   two entitled titles are installed locally, and no storefront login,
   download, or account action was automated to manufacture a third.
2. Whichever second title is measured must be reconciled against result 06's
   Wine commit so both titles report against one runtime.

Snapping the auxiliary delay-load IAT before the first call is confirmed to fix
the defect: with `sechost` snapped, the reproducer prints `PASS` and `x5`
arrives as `0x10`. Doing that snapping eagerly at load time is not a viable
mechanism, though — `rpcrt4` alone delay-loads `user32`, `ole32`, `oleaut32`
and `wininet`, so it converts delay-loading into eager loading across most of
the Wine dll graph and broke process startup. #59 carries the details and the
trampoline design that replaces it.
