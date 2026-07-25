# CPU-001 result 20 — guest calls through a null pointer now reach the guest handler: the issue's premise was wrong, wine needed no change, and the fix was two registers

**Author:** Tim Isaev
**Date:** 25 July 2026
**FEX:** `alloy/task-20-null-call` @ `ff1a395` (on `98d5e2d`) ·
**Wine:** `alloy/task-12-fault-census` @ `619c4c0`, unmodified for this work ·
**Hardware:** M2 Pro, 16 GB, macOS 26.5

## Outcome

Issue #20 asked to make an instruction-fetch access violation at address 0 reach
the guest's `__except`/VEH handler, as it does on Windows. It does now:

```text
null call detail: info0=8 addr=0x0 (expect info0=8 addr=0x0)
null call: 100/100 caught
cpu-001 seh nullcall ok
```

`seh_nullcall.exe` exits 0 on the main thread and workers; the corpus is 31/31.
Two FEX changes, no wine change, and the issue's stated cause was wrong in a way
that would have led to a wine change that made things worse (§1).

## 1. The premise, and why it mattered that it was wrong

Issue #20 states that FEX declines the fault and "Wine cannot dispatch it either",
citing wine's `invalid frame` complaint. That framing invites loosening wine's
exception-frame validation. Measured, FEX's pass-through produced an exception
that was **correct in every field except one register**:

```text
dispatch_exception code=c0000005 addr=0  info[0]=8  info[1]=0
  rip=0  rsp=00007ffeddf60000  rbp=0000000109fefeb0  cs=0033
err:seh:call_seh_handlers invalid frame 7ffeddf60008 (0000000109EF8000-0000000109FF0000)
```

`rsp` and `rbp` are on **different stacks**: `rbp` is inside the reported limits,
`rsp` is not. Against a case that dispatches fine, same instrument:

| case | `rsp` | `rbp` | invalid-frame complaints |
| --- | --- | --- | --- |
| `seh_repeat sequential` (exit 0) | `0x10bb0ff28` | `0x10bb0ff38` | 0 |
| `seh_nullcall` (exit 5) | `0x7ffeddf60000` | `0x109fefeb0` | 1 |

In the working case both are on the guest thread stack, 16 bytes apart. In the
failing case `rsp` is the stack the **dispatcher gadget** was running on when the
guest branched to null — visible directly as `sp 0x7ffeddf60000` in the low-pc
diagnostic — while `rbp` came through correctly from its SRA register mapping.

**Wine's frame validation was correct and was the messenger.** Loosening it would
have let a handler run on a stack that is not the guest's, converting a clean
failure into silent corruption.

## 2. First change — dispatch instead of pass-through

```cpp
bool IsJIT = CTX->IsAddressInCodeBuffer(Thread, NativeContext->Pc);
if (!IsJIT && !IsDispatcherAddress(NativeContext->Pc)) {
    LogMan::Msg::DFmt("Passing through exception");
    return false;                       // Pc == 0 lands here
}
```

A null Pc is neither in the code buffer nor a dispatcher address, so FEX returned
false without reconstructing anything, and wine built the x64 context from the
native one — taking guest RSP from the native SP. Adding a null-Pc execute-fault
case routes it into `RethrowGuestException`, which derives RSP from
`Context.X[SRAGPRMapping[REG_RSP]]`, FEX's saved *guest* RSP.

Result: `rsp` and `rbp` landed on the same stack, wine raised no frame complaint,
and the guest's SEH handler was invoked for the first time. `seh_nullcall` moved
from exit 5 to exit 84 — a different failure, not a fixed one.

## 3. Second change — the RIP was a whole frame too shallow

The handler ran and **declined**, so ntdll treated the exception as unhandled.
`nullcall_probe` (added by this work) separates who sees what, against a
data-fault control that already worked:

| case | VEH | `__except` filter | caught |
| --- | --- | --- | --- |
| read through null (control) | sees it, fields correct | **runs** | yes |
| call through null | sees it, `info0=8 info1=0` correct | **never runs** | no |

The vectored handler saw a correct exception; only the SEH scope lookup failed.
That isolates it to `__C_specific_handler`, and the reported RIP explains why:

```text
1400014c1: e8 fa 00 00 00   callq 0x1400015c0 <call_through_null>
```

`0x1400014c1` is in **`main`** — the call *to* the function that faults. It is
not inside `call_through_null`'s `__try` at all, so the scope table lookup
searched the wrong function. The control reports `0x140001598`, which is
`movl (%rax),%eax`, the actual faulting instruction inside its own `__try`.

On Windows the guest is at RIP **0** with the return address already pushed, and
the unwinder resolves the scope from that return address — which is inside the
`__try`. Reporting the same fixes it:

```text
VEH    code=c0000005 addr=0000000000000000 params=2 info0=8 info1=0 rip=0
FILTER code=c0000005 addr=0000000000000000 params=2 info0=8 info1=0 rip=0
call caught=1
```

Both changes are semantic, not cosmetic. A call-site RIP is not a slightly wrong
address; it names the wrong frame, and any handler keyed on the faulting location
disagrees with it.

## 4. The #6 carve-out is now live, and exercised

Issue #6 added a refusal in `RethrowGuestException` for a packed RIP of zero, carving
out the case where the guest genuinely branched into the null page
(`ExceptionInformation[0] == 8 && ExceptionInformation[1] == 0`). #20 predicted
that carve-out "becomes live exactly when this is fixed". That is literally true:
it is the landing site for both changes here.

Verified rather than assumed — a `seh_nullcall` run emits **0** refusals and
**100** context reconstructions, matching the 100 null calls the guest catches.
The carve-out went from unreachable defensive code to a path taken a hundred
times per run.

## 5. Regression

31/31 against the isolated census runtime (FEX `ff1a395`, wine `619c4c0` with the
census inert):

| group | result |
| --- | --- |
| plain corpus, 16 tests incl. `seh_nullcall` | green |
| `seh_multi` × 5 shapes, `seh_repeat` × 3 shapes | green |
| `jit_cross_view` × 5 modes (#30) | green |
| `x64hello`, `nullcall_probe` | green |

`seh_nullcall` was the only red test before this change and is green after; no
test moved the other way.

## 6. What this does not cover

The guest resumes by unwinding, never by continuing at RIP 0. A handler that
returns `EXCEPTION_CONTINUE_EXECUTION` from a null branch would resume into the
null page and re-fault — which is exactly the wedge #6's refusal was written to
prevent, and it remains prevented for every other zero-RIP case. Windows has the
same property, so this is not a divergence, but nothing here tests it.

The reported RSP is FEX's saved guest RSP, which is correct for unwinding. Whether
the return address it points at is bit-identical to what Windows would have pushed
is not verified — the unwinder finding the right scope 100 times out of 100 is
strong evidence, not proof.

## Doctrine reinforced

Result 19 ended on the rule that an instrument is evidence only after it has been
made to fail on purpose. This result adds the companion: **a bug report's stated
cause is a hypothesis, not evidence.** #20 named FEX declining and wine failing to
dispatch. FEX did not decline in any way that mattered, wine's validation was
right, and the fix touched neither of the places the issue pointed at. Taking the
premise at face value would have produced a wine change that let handlers run on
the wrong stack — a worse defect than the one being fixed, and a silent one.

The separation that made it tractable was cheap: a vectored handler and an
`__except` filter that print what they receive, plus a control that already
worked. Two runs of that probe turned "the guest never catches it" into "the
scope lookup uses a RIP from the caller's frame".
