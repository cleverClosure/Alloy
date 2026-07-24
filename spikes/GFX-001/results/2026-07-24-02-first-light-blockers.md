# GFX-001 result 02 — first-light blockers: three decoded, one fixed in the fork, one remaining

**Author:** Tim Isaev
**Date:** 24 July 2026
**Wine:** `alloy/spike-wine-001` @ `0ef284d` · **DXMT:** e520fea (arm64ec build,
`wine_builtin_dll=false` for guest dlls) · **Hardware:** M2 Pro, 16 GB, macOS 26.5

## Where gate 2 stands

`testcases/d3d11_smoke.c` (device + swapchain + clear + staging readback, self-verifying)
went from **instant import failure** to **DXMT init actually executing** in one session.
The remaining blocker is a spin inside FEX-space during DXMT's DllMain/CRT init. The
baseline corpus (x64hello, win_smoke, isa_smoke, jit_pages) is regression-checked green
after every fork change below. A control run against Wine's own d3d11/dxgi
(`WINEDLLOVERRIDES=d3d11,dxgi=b`) reaches `main` and fails device creation cleanly
(no GPU backend) — isolating every problem below to DXMT's dlls specifically.

## Install mechanics, decoded the hard way

The working recipe:

1. **Guest-facing dlls (d3d11, dxgi) — native files in system32.** Requires
   `-Dwine_builtin_dll=false` (meson reconfigure): with the builtin signature stamped, the
   `=n` load order *skips* them ("native" excludes builtin-signature files) while `=b`
   would prefer Wine's own build-tree d3d11. Native-signature + `d3d11,dxgi=n` wins.
2. **winemetal — a Wine builtin, with a twist.** Its unixlib attaches only for modules on
   the builtin list (`load_builtin_unixlib` → recorded `unix_path`), which only the unix
   builtin search populates. The PE loader finds dlls **only through files present in
   system32**; a builtin-signature file there reroutes into `find_builtin_dll`, which
   consults `WINEDLLPATH` and records the paired `.so`. So: builtin-stamped
   `winemetal.dll` in system32 (trigger) + `WINEDLLPATH=<dir>` with
   `<dir>/x86_64-windows/winemetal.dll` (+`.so` beside it; the pe-dir comes from the
   *importing module's machine*) and `<dir>/aarch64-unix/winemetal.so` (so-dir from the
   host machine). Note: DXMT's meson `postprocess_lib` step is supposed to stamp the
   signature via `winebuild --builtin` but the in-tree artifact was unstamped — stamp
   manually and verify bytes at DOS-stub offset 0x40.
3. **Environment**: `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib` (fonts) +
   `WINEDLLOVERRIDES="xtajit64=n;d3d11,dxgi=n"` + `WINEDLLPATH` as above.

## Fork fix that stays: EC entry points are x64 thunks (commit `f24425c`)

All three DXMT dlls (and FEX's own, machine `0xA641` all around) point
`AddressOfEntryPoint` — and TLS callbacks — at **x64 fast-forward thunks**
(disassembly: `movq/pushq/jmp` at the entry RVA). Wine's loader called them with a native
`blr`, executing x64 bytes as arm64: the observed `c000001d`, `pc=0` with
`0xcccc`-poisoned x16/x17, and absorbed near-NULL faults. FEX never hit this only because
the emulator dll's init goes through its interface exports (gate-3 redirection), not
DllMain. Fix: `arm64ec_redirect_entry()` maps entry/TLS pointers through the module's EC
redirection table before `call_dll_entry_point` (loader.c both sites; helper in
signal_arm64ec.c beside `arm64ec_get_module_metadata`). No-op for ARM64X builtins (their
entries are already arm64) and for pure-x64 dlls (no CHPE metadata). Verified: crash
signatures gone, baseline corpus unaffected.

## Fork experiment that was reverted, and its lesson (`4d5daa4` → revert `0ef284d`)

With entries fixed, init crawled: a `sample` of the spinning process showed 100% of time
in `segv_handler` at the x18 trap-and-emulate. DXMT's EC code is compiled for the Windows
x18=TEB convention — every TEB access faults (Darwin zeroes x18), at ~8.9 µs each
(result 05 economics), and offsets outside the emulated pair {0x60, 0x1788} fall through
to chaos. I generalized the handler to "repair x18 = TEB and re-execute" for any
x18-based access — which un-absorbed a **previously-benign per-thread FEX probe**
(`FEXdll+0x1018`, `[x18+0x808]`): under the old handler it failed and FEX took its
fallback path; with repair it *succeeds*, FEX takes a different path, and the whole
baseline corpus hangs. Reverted; baseline re-verified green.

**Lesson, stated as policy: out-of-tree ARM64EC dlls for this runtime are built with the
darwin-teb configuration — `-ffixed-x18` plus the TSD-slot-6 `winnt.h` override — exactly
like the FEX DLL itself. The x18 convention is fixed at build time, not emulated at
runtime.** The fault-side handler stays minimal (the founder's original two-offset
emulation) as a backstop, not a mechanism.

## Remaining frontier

1. **Rebuild DXMT with darwin-teb flags** (cross-file `c_args`/`cpp_args`: `-ffixed-x18
   -I …/darwin-teb-overlay`) and rerun — expected to remove the fault storm the same way
   it did for FEX.
2. If a spin persists: capture per-run load bases (`WINEDEBUG=+loaddll`), `sample` the
   live process, symbolize with `llvm-symbolizer --obj=<dll> 0x180000000+RVA`. A stale
   base from a previous run symbolizes to garbage — bases are per-run (ASLR).
3. **winemetal ABI risk, unverified**: DXMT vendors an older `wineunixlib.h` (declares
   `__wine_init_unix_call`, which exists in our tree via winecrt0, but also saw a
   `__wine_set_unix_env` lookup fail) — diff DXMT's unixlib expectations against wine
   11.13's ABI before trusting the bridge.

## Operational notes

- Wine guest processes carry guest argv (`d3d11_smoke.exe`), so path-scoped
  `pkill -f fex-runtime-probe` misses them — one 100%-CPU orphan survived 11 minutes.
  Kill by explicit PID from `ps aux | grep <exe name>`.
- The spin presents as `timeout` but is 100% CPU — `sample <pid>` is the tool that
  cracked it.
