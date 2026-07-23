# WINE-001 gate 2 CLOSED — TEB relocation and first native PE execution

**Author:** Tim Isaev
**Date:** 23 July 2026
**Build:** `spikes/WINE-001/work/build-1` (Wine 11.13, aarch64 host)
**Wine patches:** branch `alloy/spike-wine-001`, commits `0e693a0` (loader/VA) and `efd41b9` (TEB/TSD)

## Result

Native ARM64 Windows PE executables run on macOS under the patched Wine, with
correct output and exit codes (reproduced from a quiesced state):

```console
$ WINEBOOTSTRAPMODE=1 wine reg.exe query \
    "HKLM\Software\Microsoft\Windows NT\CurrentVersion" /v ProductName
HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion
    ProductName    REG_SZ    Windows 10 Pro
# exit 0

$ WINEBOOTSTRAPMODE=1 wine cmd /c "echo alloy-native-pe-ok & exit 42"
alloy-native-pe-ok
# exit 42   (custom code propagated through cmd.exe)

$ WINEBOOTSTRAPMODE=1 wine reg.exe query \
    "HKLM\System\CurrentControlSet\Control\ComputerName\ComputerName" /v ComputerName
    ComputerName    REG_SZ    MACBOOK-PRO
# exit 0
```

`wineboot.exe -u` (without the bootstrap shortcut) builds a **complete prefix**: a
48,000-line / 1.85 MB registry, the full `drive_c` tree, dosdevices, and Start-Menu
shortcut generation — all executed by native ARM64 PE code (ntdll, kernel32,
kernelbase, advapi32, setupapi, ole32, win32u, …). This is the gate-2 boot proof.

## Root cause fixed this session: x18 is not usable as the TEB register on Darwin

Wine keeps the current TEB in **x18** on ARM64 (the `NtCurrentTeb()` convention and a
large amount of hand-written dispatcher assembly all assume `teb = x18`). On Apple
Silicon macOS, **the kernel zeroes x18 on every exception return / kernel entry** —
it is reserved to the platform and not preserved for user code. A three-way probe
confirmed the model:

| Register | Writable at EL0? | Survives preemption/syscall/signal? | Per-thread? |
| --- | --- | --- | --- |
| `x18` | yes (but reserved) | **NO — cleared to 0** | n/a |
| `tpidr_el0` | yes | **NO — Darwin owns it** | (clobbered) |
| pthread TSD slot 6 (`[tpidrro_el0]+0x30`) | yes | **YES** | **YES** (probe: isolated across threads) |

So the fix mirrors what Wine already does on x86_64 macOS: store the TEB in the
pthread TSD, in **slot 6** (byte offset 0x30 from `tpidrro_el0`), a slot Darwin's
own runtime leaves free (verified: reads 0, survives libc/malloc/signal stress,
per-thread isolated).

### The subtle part: the PE build is compiled in MSVC mode

Patching only the `__GNUC__` branch of `NtCurrentTeb()` in `winnt.h` did nothing for
the PE side. Wine's PE modules are cross-compiled with `-target aarch64-windows`,
under which clang defines `_MSC_VER` and **not** `__GNUC__`. The active definition
was therefore the MSVC branch:

```c
return (struct _TEB *)__getReg(18);   /* reads x18 */
```

which every PE C function inlined (624 x18 accesses in ntdll.dll, 37 in services.exe).
Both aarch64 branches now read TSD slot 6; clang's `__builtin_arm_rsr64("tpidrro_el0")`
emits the right `mrs`/`ldr` under the MSVC target. After the fix: ntdll.dll 624 → 1
x18 refs, services.exe 37 → 0.

### Change set (commit `efd41b9`)

- `include/winnt.h` — both aarch64 `NtCurrentTeb()` branches (GNUC and MSVC) read the
  TEB from TSD slot 6.
- `dlls/ntdll/unix/virtual.c` — `virtual_alloc_first_teb` publishes the TEB into slot 6.
- `dlls/ntdll/unix/signal_arm64.c` — `signal_start_thread` publishes the TEB into slot 6
  for every new thread; the syscall dispatcher, unix-call dispatcher,
  `__wine_syscall_dispatcher_return`, the syscall-table load, and the trace path read
  the TEB from slot 6 instead of x18.
- `dlls/ntdll/signal_arm64.c` — the hand-written PE dispatchers (`KiUserCallbackDispatcher`,
  the exception unwind trampoline, `DbgUiRemoteBreakin`) read the TEB from slot 6.

The one remaining x18 reference in ntdll.dll is in ARM64EC-specific code, out of scope
for this pure-aarch64 build (revisit at CPU-001 integration).

## How gate 2 was reached (kill-chain, this session)

| Stage | Symptom | Fix |
| --- | --- | --- |
| loader | SIGKILL pre-main | sub-4 GB `__PAGEZERO` denial → drop loader `-pagezero_size` on aarch64 (`0e693a0`) |
| ntdll init | `failed to map shared user data` | KUSER_SHARED_DATA `0x7ffe0000` → `0x7ffe00000000` (`0e693a0`) |
| ntdll init | `out of memory` placing TEB block below 2 GB | drop `limit_2g` constraint (`0e693a0`) |
| PE C code | `EXC_BAD_ACCESS` reading `[x18,#0x17ee]` (SameTebFlags) | TEB from TSD slot 6 (`efd41b9`) |
| **console PE** | **runs, exits 0/42** | **gate 2 core hypothesis proven** |

## Known follow-ups (next spikes, not gate-2 blockers)

1. **Full graphical boot completion.** `wineboot -u` builds the whole prefix but its
   final GUI/menu stage crawls: this Wine was configured `--without-x` and without
   FreeType/gnutls, so font/graphics init has no backend
   (`Wine cannot find the FreeType font library`), and the USER message pump
   (`NtUserPeekMessage → process_driver_events`) busy-polls the server. A build with
   FreeType + a working `winemac.drv` is the graphics-spike scope. Console PEs are
   unaffected (proven above via `WINEBOOTSTRAPMODE=1`).
2. **Service subsystem.** RpcSs/NDIS autostart intermittently hangs or faults
   (`page fault reading 0x8A0` in a service thread); keeps the process group alive so a
   naive `timeout` around a console run can trip even though the console program itself
   exited 0. Left-over `wineserver`/service processes must be reaped between runs.
3. **`get_core_id_regs_arm64` is a stub** — CPU-ID register reads return nothing;
   harmless FIXME now, will matter for guest CPU feature reporting at CPU-001.
4. **ARM64EC** — the remaining ntdll x18 ref and the `env.c`/LDT `limit_2g` sites are on
   the WoW64/EC path; address them when the x64 guest layer lands (CPU-001 gate 4).

## Environment / hygiene notes

- This Mac also runs the founder's own **CrossOver** Steam (x86_64 Wine under Rosetta:
  `winewrapper.exe`/`wineserver` under `/Applications/CrossOver.app`, with Sir Brante
  installed). Those processes must never be killed during spike cleanup — filter kills
  by the `build-1/` path. All cleanup this session verified CrossOver's wineserver
  survived.
- Reproducible console-PE proof requires a quiesced process table first
  (`pkill -9 -f build-1/loader/wine; pkill -9 -f build-1/server/wineserver`), else a
  stale server/service skews the run.
