# WINE-001 result 11 — the first ARM64EC delay-import call loses every argument passed in memory, and resolving eagerly is not the way to fix it

**Author:** Tim Isaev
**Date:** 25 July 2026
**Wine:** `alloy/task-59-ec-delayload-thunks` @ `fbbdf99` (on `54048cb`) ·
**FEX:** `libarm64ecfex.dll` SHA-256 `ef4ce1be195296ae2e1bd6612efba8fae4b8f3eb37d25985b1275aae52ef7aa6` ·
**Hardware:** M2 Pro, 12 cores, 16 GB, macOS 26.5.2 (`25F84`)

## Outcome

Issue #59 came out of #11: Deus Ex: Mankind Divided died 15 s into startup in
`rpcrt4`, five runs out of five, with the graphics stack loaded but never
exercised. The cause is not in `rpcrt4` and not in the graphics stack. It is
that an ARM64EC module's **first** call to a delay-imported function leaves
ARM64EC, and a variadic callee cannot survive the trip.

- **The defect is measured, not inferred** (§1). At the ARM64EC entry `x4` is
  correct and `x5` is 0, and the memory `x4` points at holds the staging pair
  the exit thunk parked rather than the real arguments.
- **The round trip cannot be repaired where it breaks** (§2). The size is never
  encoded, so no dispatcher or entry thunk can recover it. The first call has
  to stay inside ARM64EC.
- **Resolving eagerly works and is still the wrong mechanism** (§3). It fixes
  the defect, then converts delay-loading into eager loading across most of the
  dll graph and breaks process startup.
- **A native trampoline per auxiliary slot fixes it with no semantic change**
  (§4), and the full guest corpus shows exactly one behavioural difference
  against a baseline build (§5).
- **It unblocks the title's graphics stack but not the title** (§6). Deus Ex
  now creates a D3D11 swapchain, initializes its renderer and compiles shaders
  through DXMT, then stops on an unrelated `E_INVALIDARG`.

## 1. What actually arrives

`sechost` implements `OpenSCManagerW` and delay-imports `rpcrt4`,
`NdrClientCall2` among them. That function is variadic, and its ARM64EC
definition depends on the ARM64EC variadic contract — `x4` pointing at the
x64-shaped stack argument block, `x5` its size:

```asm
stp x2, x3, [x4, #-0x10]!   /* fold the register varargs onto the block */
mov x2, x4                  /* ... and take that as stack_top */
```

A probe on `x4`/`x5` at that entry, on the failing call:

```text
main: 0 0 0x109C8FDA0 0x10 0x109C8FE08
varargs x4 0x109C8FD80 x5 0 (expected x4 0x109C8FD80)
varargs block: 0x109C8FDA0 0x10
```

`x4` is exactly `stack_top + 0x10`, which is right. `x5` is 0. And the memory
`x4` points at holds `(0x109C8FDA0, 0x10)` — the pointer-and-size pair the exit
thunk staged with `stp x4, x5, [sp, #0x20]`, read back as if it were the two
real stack arguments.

So `ROpenSCManagerW` receives `0x10` — the staged byte count — where it expects
`&SC_HANDLE`, and `NdrContextHandleUnmarshall` writes NULL through it. That is
the `c0000005` at `rpcrt4 + 0x64aac` that ends the title.

Arguments passed in registers survive; arguments passed in memory do not.

## 2. Why it cannot be fixed at the hop

The path on a first call is: ARM64EC caller → the auxiliary delay IAT slot,
still holding the `__impchk_` thunk → the regular delay IAT, still the x64
delay stub → `__os_arm64x_check_icall` diverts to
`#NdrClientCall2$exit_thunk` → `$iexit_thunk$cdecl$i8$varargs`, which stages
`x4`/`x5` and calls `__os_arm64x_dispatch_call_no_redirect` → the emulator →
back into ARM64EC through an entry thunk.

Each piece is individually correct. `sechost`'s call stub forwards `x0`–`x5`
untouched. `arm64x_check_call` uses only `x9`, `x16` and `x17`, so it preserves
the argument registers. The exit thunk is variadic-aware and stages the pair
deliberately.

What is missing is anyone expanding that staged block into the x64 stack. The
entry thunk on the way back sets `x4 = rsp+0x20` and, having no way to know a
size it was never given, `x5 = 0`. A generic dispatcher cannot know its caller
was a variadic exit thunk, and the size is not encoded anywhere it could read.
Repairing the hop is therefore not available: the first call has to not make
the trip.

## 3. Eager resolution: correct result, unacceptable mechanism

Snapping the auxiliary slot before the first call does fix the defect. With
`sechost` snapped the reproducer passes and `x5` arrives as `0x10`. Two
placements were tried and both rejected:

| Placement | Result |
| --- | --- |
| `fixup_imports` | Hangs. Resolving there re-enters the loader while the module graph is still being built. |
| `process_attach`, one level deep | Boots, but skips 24 of 56 modules — `sechost` among them — so the title still crashes. |
| `process_attach`, deferred-queue drain | Snaps everything and breaks process startup: guests exit 1 with no output. |

The reason is visible in what gets pulled in. `rpcrt4` alone delay-loads
`user32`, `ole32`, `oleaut32`, `wininet`, `secur32` and `ws2_32`; a full drain
also reached `shell32`, `urlmon`, `crypt32`, `comdlg32`, `mlang` and
`dhcpcsvc`. Eager snapping converts delay-loading into eager loading across
most of the dll graph, during early loader init. That is too much semantic
change to carry for this, independent of whether some variant could be made to
boot.

## 4. What landed instead

Each auxiliary delay-load IAT slot gets a native ARM64 trampoline, installed at
module load. Installation resolves nothing and loads no dll — it only rewrites
slots — so delay-load semantics are untouched and nothing loads earlier than it
does today.

The trampoline preserves `x0`–`x5` and `q0`–`q7` across the resolver and
tail-jumps to the callee's ARM64EC entry, so the first call never leaves
ARM64EC and `x4`/`x5` are simply passed through. Each stub is 64 bytes: four
instructions that load their own context pointer and branch to a shared entry
in `ntdll`, followed by the context. The page is made executable before any
slot points at it, so the stubs are never writable and reachable at once.

Two details are load-bearing:

- The existing `arm64ec_redirect_delayload` snaps the slot to the ARM64EC entry
  as the resolver returns, which is what the trampoline reads back and jumps
  to. That redirection was already correct; on its own it just ran one call too
  late to help.
- A trampoline that cannot establish an ARM64EC target hands the call back to
  the `__impchk_` thunk it replaced. A redirection is the only proof on hand
  that a target is ARM64EC, and branching directly into something that turns
  out to be x64 would execute it as ARM64.

## 5. Verification

A guest, `spikes/WINE-001/testcases/ec_delay_import.c`, calls `OpenSCManagerW`
once behind a vectored handler and fails at the same `rpcrt4` address as the
title. It is the regression gate: `FAIL raised 0xc0000005 at 00006FFFFE934AAC`,
exit 3, before; `PASS`, exit 0, after.

The whole 22-guest corpus was run against a baseline build and against the
fixed build, same prefix, same policy:

| | Baseline | Fixed |
| --- | --- | --- |
| `ec_delay_import` | 3 | **0** |
| `guard_enforce` | 1 | 1 |
| `jit_cross_view` (no mode) | 64 | 64 |
| `seh_nullcall` | 5 | 5 |
| `x64min` | 42 | 42 |
| the other 17 | 0 | 0 |

One behavioural change, and it is the target. `guard_enforce`'s failure and the
non-zero exits that are by design are unchanged. Comparing stdout rather than
just exit codes leaves only addresses, PIDs and the CPUID leaf-1 topology
bits — run-to-run noise.

`jit_cross_view` passes all five modes, which matters here because the
trampolines take an executable allocation and #30's MAP_JIT handling is what
would notice:

```text
positive              PASS exact-bytes scalar vector atomic threads
rx-target             PASS rejected with an access violation
decommitted-target    PASS rejected with an access violation
decommitted-crossing  PASS rejected with an access violation
non-temporal          PASS exact-bytes
```

Sir Brante, result 06's title, still boots: headless exit 0 with the ordinary
Unity asset lifecycle, and graphical exit 0 having recorded **7,479 presents**
through DXMT. The only log line matching error patterns is
`SteamAPI_Init() failed`, which is expected in an isolated prefix.

## 6. What it unblocks, and what it does not

Deus Ex: Mankind Divided installs 29 trampolines and no longer dies in
`rpcrt4`. It now reaches, in order: window created, `[DXGI] Created swapchain`,
`[SwapChain] Successfully created`, `[NxApp] Swapchain initialized`,
`[NxApp] Renderer initialized`, `[Scaleform] Initializing` — and DXMT writes a
shader cache, so the graphics stack is genuinely running.

It then stops on `e06d7363` (a C++ throw) during Scaleform initialization,
carrying `0x80070057` — `E_INVALIDARG`. That is a different defect from this
one and, given where it surfaces, is a graphics-side gap rather than a loader
one. #59 is closed on the defect it describes; the new blocker is filed
separately and belongs to #11's track.

The `NdrpClientCall2` probe used for §1 remains in the local `rpcrt4` build. It
is diagnostic scaffolding, not a runtime error, and rebuilding `rpcrt4` without
it is worth doing before #11 takes measurements that include its logs.
