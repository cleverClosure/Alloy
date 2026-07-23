# WINE-001 gate 3 — Wine-side loader→emulator handshake PROVEN on macOS

**Author:** Tim Isaev
**Date:** 23 July 2026
**Status:** Wine-side gate 3 **closed**. x64 guest PEs load through the ARM64EC
loader, the emulator interface initializes, and control reaches the emulator
hand-off — verified with the Alloy stub emulator, exit 0, no faults.

## Result

```
$ WINEDLLOVERRIDES=xtajit64=n WINEDEBUG=warn+debugstr wine C:\x64min.exe
alloy-emu-stub: ProcessInit: EC loader reached the emulator; init OK
alloy-emu-stub: ExitToX64: x64 code transfer requested - Wine-side plumbing proven; exiting (stub).
(exit 0)
```

Both test guests pass: `x64min.exe` (freestanding, no imports — first x64
instruction is the entry point) and `x64hello.exe` (full mingw CRT: imports
ucrtbase→kernel32→kernelbase, TLS callback, 4K-aligned sections — the shape of
a real Windows binary). Native ARM64X execution regression-checked
(`reg query` and `cmd` still correct).

The `EACCES` blocker from the gate-3 groundwork note is root-caused and fixed —
and it was **not** a capped `max_protection`: a `mach_vm_region_recurse` dump at
the failure site showed `max_protection = RWX` on every failing region. The
denial is macOS-arm64's categorical refusal of **RWX on non-`MAP_JIT` memory**,
triggered through Wine's 4K-guest-page-on-16K-host-page packing. Four distinct
defects stacked on top of it; each was identified from register-level evidence
and fixed:

## Kill-chain (in discovery order)

1. **Transient RWX unions in `map_image_into_view`** (the original ERR):
   `get_host_page_vprot()` returns the union of the 4 guest pages in a host
   page. Mid-way through the per-section protection loop a host page can hold
   already-EXEC pages next to still-`WRITECOPY` pages → union RWX → `mprotect`
   EACCES. Self-heals when later sections re-protect the same host page; noisy
   but non-fatal for our binaries. (Would NOT self-heal for a page whose last
   protected section is EXEC.)
2. **Fatal: unchecked `NtProtectVirtualMemory` in
   `arm64ec_update_hybrid_metadata`** (signal_arm64ec.c:303): making the CHPE
   metadata slots writable in a 4K-aligned EC dll unions with neighboring
   `.text`/`.hexpthk` EXEC bits → RWX → `STATUS_ACCESS_DENIED` (seen live in
   x0 at the fault) → the unguarded pointer write faults. Every pre-init
   exception then died in a **NULL-dispatch recursion**:
   `prepare_exception_arm64ec` compares against `KiUserExceptionDispatcher_orig`
   which is only initialized at `arm64ec_process_init`+222 — before that the
   memcmp reads all-zeros, concludes "thunk modified", and `blr`'s the
   still-NULL `__os_arm64x_dispatch_call_no_redirect` (KiUserExceptionDispatcher
   asm, line ~1327) → fault at pc 0 → redispatch → ~2.3 KB stack per iteration
   → "stack overflow 224 bytes" abort. **Fix (Wine, `mprotect_exec`)**: on
   Apple arm64, when `mprotect` fails EACCES with WRITE|EXEC requested, retry
   without EXEC. Writes have no recovery path, while dropped host-EXEC is
   by-design recoverable: executing such a page faults into
   `KiUserEmulationDispatcher` (signal_arm64.c:370), which is precisely how
   guest x64 code is meant to run under FEX. Under the emulator, **guest x64
   pages never need host EXEC at all.**
3. **lld ARM64EC exports are fast-forward sequences**: all 20 stub exports
   resolve into `.hexpthk` (x64 thunk code). Wine takes the dispatch trio
   (`ExitToX64`/`DispatchJump`/`RetToEntryThunk`) raw from
   `RtlFindExportedRoutineByName` and `blr`'s it from native code — executing
   x64 bytes as AArch64. Winebuild-linked dlls (Wine's builtin) export native
   addresses, masking this upstream. **Fix (Wine,
   `arm64ec_process_init`)**: resolve the trio through `arm64ec_redirect_ptr`
   too — maps FFS→native via the `.a64xrm` redirection metadata and is a no-op
   for already-native exports. **FEX's lld-built `libarm64ecfex.dll` needs this
   same fix, so it belongs on the fork permanently.**
4. **Emulator import-chain ordering**: linking the stub against the mingw CRT
   made xtajit64.dll import ucrtbase→kernel32→kernelbase. Those load (and get
   their `__os_arm64x_*` slots stamped from the ntdll statics) **during**
   `load_dll(xtajit64)` — before `arm64ec_process_init` resolves the statics —
   so every exit thunk in kernel32 held NULL. Diagnosed by logging each
   module's stamped value: all NULL, then the trio resolving *after*. **Fix
   (stub)**: build freestanding (`-nostdlib -lmingwex -lntdll`, own
   `DllMainCRTStartup`) — imports = ntdll only, like real xtajit64. With that,
   kernel32 loads after emulator init and its slot gets the real pointer.
   *Wine fragility to remember: any emulator dll with dependencies breaks the
   stamping order silently.*

Also fixed in the stub: `ProcessInit` runs before any DLL initializers, so
logging now uses ntdll `DbgPrint` (visible via `WINEDEBUG=warn+debugstr`)
instead of CRT stdio (whose uninitialized function pointers caused the very
first NULL-call crash observed), exit via `RtlExitUserProcess`, sections
64K-aligned like every other EC module, and the dispatch trio logs-and-exits
instead of returning (the real thunks never return; returning corrupted SP —
seen as an SP-alignment fault mid-transition).

## Evidence trail

- `mach_vm_region_recurse` dump at the map failure: `max 7` everywhere,
  anonymous (`pager 0`) — killed the max_protection theory in one run.
- Rate-limited register dump in `segv_handler` for low-pc faults: identical
  `lr` per iteration → symbolized to `KiUserExceptionDispatcher`+0x?? (the
  `blr x16` at signal_arm64ec.c:1327), `x9` = `#EXP+#KiUserExceptionDispatcher`
  (the x64 thunk), `x16 = 0` — the NULL dispatch pointer, caught red-handed.
- `llvm-symbolizer` against the ARM64X `aarch64-windows/ntdll.dll` (DWARF in
  the debug sections) resolves crash addresses to file:line without a debugger;
  the arm64ec-windows dir holds only objects.
- Fault #1 with `x0 = 0xc0000022` (STATUS_ACCESS_DENIED live in a scratch
  register) pinned the unchecked-NtProtectVirtualMemory write.
- `$iexit_thunk$cdecl$i8$i8` disassembly: `ldr x16, [x8, #0x740]` → RVA 0xB0740
  → kernel32's `.data` CHPE slot → stamped-NULL confirmation.

## What this proves / what remains

**Proven (Wine-side gate 3):** EC hybrid Wine on macOS/ARM64 loads a true x64
main image, loads + initializes the emulator dll (`ProcessInit`,
feature probes, `ThreadInit`), stamps hybrid metadata across modules, resolves
imports on 4K-aligned guest binaries, and transfers the first x64 execution
(TLS callback or entry point) into the emulator's `ExitToX64`. Everything FEX
needs from the loader is in place.

**Remaining for full gate 3 / CPU-001 gate 4 (founder-only, FEX policy):**
- FEX `FEXUnixLib` Darwin port; swap the stub for `libarm64ecfex.dll`.
- FEX-side: verify x18 (TEB) handling on Darwin (x18 zeroed on kernel entry;
  Wine-side reads use TSD slot 6 — the FEX register model must match).
- The trio-redirect fix (item 3) applies to FEX's dll as-is.

**Deferred (noted, not gate-3 blockers):**
- `wineboot --init` never exits (services subsystem spins; kill after prefix
  creation — same behavior as gate 2's follow-up list).
- Known VA-floor noise: `try_map_free_area` ENOMEM at 0x100000000 and
  `map_fixed_area` failures at 0x400000 for low-base PE loads (relocation
  handles them).
- A host page whose *final* protection genuinely needs W+X (writable section
  sharing a 16K page with needed-native-EXEC code) has no answer without
  MAP_JIT; probe results: `MAP_JIT|MAP_FIXED` = EINVAL, and MAP_JIT writes
  need per-thread `pthread_jit_write_protect_np` toggling. Not needed while
  EC modules stay 64K-aligned (all Wine-built ones are; Alloy controls its
  own EC dlls). Revisit only if third-party 4K EC dlls must load.
- Upstream fragilities worth carrying as fork patches: unchecked
  `NtProtectVirtualMemory` in `arm64ec_update_hybrid_metadata`; pre-init
  exceptions dispatching through uninitialized `KiUserExceptionDispatcher_orig`.

## Reproduce

```sh
TC=tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin
# stub (freestanding, ntdll-only imports, 64K sections)
$TC/arm64ec-w64-mingw32-clang -shared -nostdlib -O2 \
    -Wl,--file-alignment,0x10000,--section-alignment,0x10000 \
    -o xtajit64.dll stub_emulator.c stub_emulator.def -lmingwex -lntdll
# guests
$TC/x86_64-w64-mingw32-clang -nostdlib -Wl,-e,entry -o x64min.exe testcases/x64min.c
$TC/x86_64-w64-mingw32-clang -O2 -o x64hello.exe testcases/x64hello.c
# prefix: wineboot -u (kill when it spins; prefix is complete), then
printf disable > $WINEPREFIX/.update-timestamp
cp xtajit64.dll $WINEPREFIX/drive_c/windows/system32/
WINEDLLOVERRIDES=xtajit64=n WINEDEBUG=warn+debugstr wine 'C:\x64min.exe'
```

Wine patches: branch `alloy/spike-wine-001` in `third_party/src/wine`
(this session's commit on top of `8870df9`).
