# WINE-001 follow-up — wineboot/explorer CPU spin: root cause and fix

**Author:** Tim Isaev
**Date:** 24 July 2026
**Status:** Resolved. Cold prefix boot now completes in ~12 s with a clean
process table; the fault storm behind the spin is eliminated at the source.

## Symptom

Every session touching a Wine prefix left the machine progressively worse:

- `wineboot --init` pinned a core (~60–95 %) and either never exited or took
  4–5 minutes; earlier sessions worked around it by killing it after prefix
  creation and writing `disable` into `.update-timestamp` (workaround now
  obsolete).
- `explorer.exe /desktop` spun at 50–150 % CPU per instance and **survived its
  own wineserver**: at diagnosis time a dozen orphans from prior sessions had
  been burning 1–3.5 h of CPU each.
- Secondary weirdness, all storm side-effects: a second `services.exe`
  generation mid-boot, and the unix launcher reporting exit 0 while
  `wineboot.exe` kept burning CPU (main thread exited; the message-pump thread
  never processed its termination signal because it was trapped in the storm).

## Evidence chain

1. `sample` of the spinners: the hot thread sat in
   `NtUserGetMessage`/`NtUserPeekMessage` → `process_driver_events`
   (win32u `message.c`) with ~88 % of samples inside `_sigtramp` /
   `segv_handler` / `virtual_handle_fault` — a signal storm, not a busy
   message loop. A neighboring thread in the same process blocked cleanly in
   `server_select`, exonerating the wait machinery.
2. The orphaned explorers spun with **no wineserver alive**, so the hot loop
   makes no server calls: it is `check_internal_bits()`'s seqlock retry loop
   reading the shared session queue — pure CPU, immortal.
3. Rate-limited fault logging added to `segv_handler`: **82 of 82 logged
   faults were reads of `0x7ffe0324`** — `KUSER_SHARED_DATA.TickCount.High1Time`
   — from multiple PCs (win32u.so tick reads; PE `kernelbase`/`kernel32`
   readers), every one an unresolved `STATUS_ACCESS_VIOLATION`. With the
   limiter (first 64, then every 20 000th), 82 lines ≈ **360 000 faults in
   40 s**. Message pumps read the tick count every iteration; each read cost a
   SIGSEGV → absorbed as a failed syscall → retried. That is the storm.

## Root cause

Commit `0e693a03` (23 Jul) relocated the user shared data to
`0x7ffe00000000` because the architectural address `0x7ffe0000` sits below
the arm64-macOS VA floor — but only ntdll (unix + PE `thread.c`) was
repointed. Four modules kept private statics at the dead low address, so
every tick-count read they made faulted forever:

- `dlls/win32u/message.c` (unix side — the message-pump reader, worst burner)
- `dlls/kernelbase/sync.c`, `dlls/kernel32/sync.c`,
  `dlls/kernel32/process.c` (PE side)

## Platform probes — the VA floor is hard

New empirical facts (probe binaries, this machine, macOS 26.5.2):

- mmap `MAP_FIXED` anywhere below 4 GB in a default arm64 binary: `ENOMEM`.
- Linking with `-pagezero_size 0x10000`: the linker accepts it; **the kernel
  SIGKILLs the binary at exec** (exit 137, no crash report). Adding
  `-no_fixup_chains` changes nothing.
- `mach_vm_deallocate` of a pagezero slice returns `KERN_SUCCESS` but is a
  no-op — there is no mapping to remove; the 4 GB floor is the task's minimum
  VM address, not a real `__PAGEZERO` mapping.

Conclusion: **native arm64 macOS processes can never map VA below 4 GB.**
(Rosetta x86_64 processes keep the low floor — which is why every existing
Mac Windows-gaming stack stays on Rosetta.)

## Fix

Repoint the four statics to the relocated address (same one-line comment
idiom as `0e693a03`, `grep 0x7ffe00000000` finds all sites). Kept in
`segv_handler`: a rate-limited log of *unresolved* access violations, so the
next fault storm identifies itself in one run.

## Verification

| Check | Before | After |
| --- | --- | --- |
| Cold `wineboot --init` | 4–5 min or never, core pinned | **12 s, exit 0** |
| Faults logged during boot | ~10 000/s sustained | **0** |
| Post-boot process table | spinning explorer + stragglers | empty |
| `reg query` ProductName | Windows 10 Pro | Windows 10 Pro |
| `cmd /c echo` | ok | ok |
| `x64min.exe` under stub emulator | exit 0 + markers | exit 0 + markers |

## Implications for CPU-001 gate 4 (FEX, founder-only)

The VA floor is a **design input for the FEX Darwin port**, not just a Wine
bug: FEX's thin memory model equates guest and host VA, but x64 games read
`0x7ffe0000` directly (compilers inline `GetTickCount` as a literal-address
load) and legacy non-ASLR images link at `0x400000`. Neither can exist
host-side. Options, in rough order of leverage:

1. **Translate-time literal remap**: the JIT sees constant addresses; rewrite
   sub-4 GB literals in the USD page range to the relocated page — near-zero
   cost for the dominant inlined-read pattern.
2. **Trap-and-emulate fallback** for computed sub-4 GB accesses: decode the
   faulting instruction in the SIGSEGV path and service the read (precedent:
   `ntoskrnl.exe/instr.c` does exactly this for x86 drivers reading USD).
3. Wine-built PE dlls are already repointed, so Wine-side Windows code never
   touches the low page; only guest-inlined accesses remain.
4. Low-base image loads already relocate today (`map_fixed_area` failure →
   relocation); WOW64/2G layouts stay deferred per the gate-3 notes.

## Reproduce / verify

```sh
W=spikes/WINE-001/work
rm -rf $W/pfx-bootspin
WINEPREFIX=$W/pfx-bootspin $W/build-2/loader/wine wineboot --init   # ~12 s, exit 0
# storm detector: any "unresolved fault #" burst in stderr means a new storm
```

Wine fix: branch `alloy/spike-wine-001`, commit on top of `24bad68`
(5 files: 4 repointed statics + gated fault logger).
