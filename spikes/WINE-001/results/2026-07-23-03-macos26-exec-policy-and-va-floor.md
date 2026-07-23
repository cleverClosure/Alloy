# WINE-001 gate 2 — loader SIGKILL root cause, macOS 26 exec policy, and the 4 GB VA floor

**Author:** Timur Isaev
**Date:** 23 July 2026
**Build:** `spikes/WINE-001/work/build-1` (Wine 11.13, aarch64 host, `--with-mingw --without-x`)
**Wine patches:** branch `alloy/spike-wine-001` in `third_party/src/wine`

## Summary

The wine loader SIGKILL (exit 137, pre-main) is **solved**: macOS 26 on Apple Silicon
refuses to execute any binary whose Mach-O declares a `__PAGEZERO` smaller than the
default 4 GB. Wine's Darwin loader link flags (`-pagezero_size 0x1000`, unconditional
since the x86 era) trigger the refusal. Removing the flag lets the loader run:
`wine --version` → `wine-11.13`.

Downstream of that fix, the same platform property surfaced as a **hard 4 GB virtual
address floor**: a native arm64 process cannot create any mapping below 4 GB, ever.
Three Wine patches later, `wineboot` creates the configuration directory, wineserver
runs, and multiple Wine processes execute — the remaining failures are ordinary
porting bugs (thread-stack guard handling), not platform blockers.

## 1. Kill-chain diagnosis

Observed: `loader/wine` exits 137 (SIGKILL) before `main()`; no crash report is
written. `wineserver` from the same build runs fine.

Unified log (the decisive evidence):

```text
kernel (AppleSystemPolicy) ASP: Sleep interrupted: ref 6532, signal 0, pid: 3969
kernel (AppleSystemPolicy) ASP: Security policy would not allow process: 3969,
    .../spikes/WINE-001/work/build-1/loader/wine
```

`AppleSystemPolicy` (ASP) is Gatekeeper's kernel enforcement, consulting `syspolicyd`.
For allowed execs the log shows `evaluation result: ... allowed, cache`; for the wine
loader the wait ends in `Sleep interrupted` with no verdict and the exec is denied
(fail-closed).

Hypotheses eliminated before the real cause (each by direct experiment):

| Hypothesis | Test | Result |
| --- | --- | --- |
| Invalid/stale signature | `codesign --verify --strict` | valid; not the cause |
| Quarantine xattr | `xattr -l` | only `com.apple.provenance`, same as wineserver |
| Gatekeeper path/cache state | copy to fresh path, re-exec | still killed |
| 4 KB segment layout on 16 KB kernel | relink with `-segalign 0x4000 -pagezero_size 0x4000` | still killed |
| Embedded `__info_plist` (app-like binary) | relink without sectcreate | still killed |
| Provenance-sandboxed parent (agent tree) | exec via `launchctl` (clean context) | still killed (`LastExitStatus = 9`) |
| Signature trust level | re-sign with valid Apple Development identity | still killed |
| Machine rejects all fresh binaries | hello-world, default flags | runs |

Bisect on link flags (hello-world and wine `main.o`, identical outcomes — the rule is
content-independent):

| Link flags | Verdict |
| --- | --- |
| `-pagezero_size 0x1000` (Wine upstream) | SIGKILL |
| `-pagezero_size 0x4000` | SIGKILL |
| `-pagezero_size 0x4000 -image_base 0x200000000` | SIGKILL (`-image_base` ignored under PIE) |
| `-segalign 0x4000` only | runs |
| no special flags | runs |

**Rule: `__PAGEZERO` vmsize < 4 GB ⇒ exec denied.** Signature quality, notarization
status, xattrs, parent process, and file path are all irrelevant. `-no_pie` is ignored
on arm64 (PIE mandatory), so upstream's x86_64 escape (`-image_base 0x200000000` +
zerofill reserve segments + tiny pagezero) cannot be expressed at all.

## 2. Consequence: the 4 GB VA floor

With the mandatory default `__PAGEZERO`:

- first mapped region of a process starts at ≈ `0x102880000`;
- `mach_vm_deallocate` of the low 4 GB returns success but is a no-op;
- `mmap MAP_FIXED` and `mach_vm_allocate VM_FLAGS_FIXED` at `0x7ffe0000` fail
  (`ENOMEM` / `KERN_INVALID_ADDRESS`): below-floor addresses are *invalid*, not busy.

The floor is fixed at exec time by the pagezero declaration; there is no runtime
reclamation. Native arm64 processes on macOS 26 simply have no VA below 4 GB.

This is why CrossOver/Whisky still ship x86_64 Wine under Rosetta: translated
processes keep the x86_64 personality (4 KB pages, small pagezero legal). Nobody has
shipped native-arm64 Wine on macOS; upstream's `configure.ac` still routes
`aarch64-darwin` through the generic `*)` case with x86-era loader flags.

## 3. Wine patches (branch `alloy/spike-wine-001`)

1. **`configure.ac`** — darwin `WINELOADER_LDFLAGS`: `aarch64` case drops
   `-segalign/-pagezero_size`, keeps the `__info_plist` sectcreate. (Build-1's
   generated Makefile was hand-fixed equivalently; reconfigure regenerates.)
2. **`dlls/ntdll/unix/virtual.c` + `dlls/ntdll/thread.c`** — `KUSER_SHARED_DATA`
   relocated `0x7ffe0000` → `0x7ffe00000000` (both sides of the PE/unix boundary,
   single constant each). First attempt `0x7ffe00000` (~34 GB) collided with malloc
   arenas (`STATUS_CONFLICTING_ADDRESSES`); the high address just under Wine's
   reported host limit (`0x7ffffe000000`) maps cleanly.
3. **`dlls/ntdll/unix/virtual.c`** (`virtual_alloc_first_teb`) — `teb_block` reserve
   dropped its `limit_2g - 1` constraint (Windows places TEBs below 2 GB so pointers
   survive 32-bit truncation; impossible here, unneeded for x64-only scope).

Boot progression across the patches:

| State | Failure |
| --- | --- |
| unpatched loader | SIGKILL pre-main |
| loader flags fixed | `failed to map the shared user data: c0000017` (KUSD at 0x7ffe0000 below floor) |
| KUSD → 0x7ffe00000 | `c0000018` (malloc-arena collision) |
| KUSD → 0x7ffe00000000 | teb_block: `couldn't map free area in range 0x10000-0x80000000` |
| teb_block limit lifted | **prefix boot proceeds**: config directory created, wineserver up, multiple processes running |

## 4. Current frontier (next iteration)

- `virtual_setup_exception stack overflow 640 bytes addr 0x6fffffcdd804` on worker
  threads — thread-stack guard/commit handling; suspect 16 KB-host-page vs 4 KB
  Windows-page guard interaction in stack setup, macOS-specific. Ordinary porting bug.
- Repeated benign-looking `try_map_free_area ... range 0x100000000-0x100110000`
  (attempts at exactly 4 GB where the main image lives; Wine retries elsewhere).
- `env.c` `build_wow64_parameters` still carries `limit_2g - 1` — not on the pure
  aarch64 boot path, but ARM64EC x64 guests run as a WoW64-style configuration, so
  this site (and the LDT allocation in `virtual.c`) will need the same treatment at
  CPU-integration time.

## 5. Design consequence for the x64 guest path (flagged for ADR)

The VA floor is a **product-architecture fact**, not a spike inconvenience:

- **KUSER_SHARED_DATA**: real x64 game binaries read `0x7ffe0000` directly (inlined
  QPC/TickCount reads). Our EC-side system DLLs can be built against the relocated
  address, but guest x64 code cannot. Candidate strategy: FEX JIT rewrites guest
  absolute accesses to the KUSD page (immediate-address loads are statically
  rewritable at translation time); computed-address hits fault into the Mach
  exception handler and get emulated (rare in practice). To be validated in
  SPIKE-CPU-001's correctness gates.
- **Low-address `VirtualAlloc`**: x64 titles requesting explicit bases < 4 GB will
  fail; rare for modern x64 (images based at `0x140000000`+), and certification
  catches offenders per-title.
- **32-bit auxiliary helpers** (ADR-0011 carve-out): a 32-bit-VA view is
  unimplementable in-process under the floor. Helper strategy must be revisited —
  options include running helpers as separate emulated processes with a synthetic
  low-VA mapping via FEX's software address translation, or dropping 32-bit helper
  support. Decision deferred to CPU-001 follow-up.
- **Apple feedback**: file a report asking for a sanctioned low-VA opt-in
  (entitlement) for emulation runtimes; the pagezero exec-denial appears undocumented.

## 6. Environment notes

- All spike link experiments used scratchpad copies; the build tree carries only the
  Makefile loader-flag fix (regenerated on reconfigure) — source-of-truth fix is in
  `configure.ac` on the branch.
- A second Wine installation runs on this machine (CrossOver-style `wineloader`
  processes hosting Steam x86_64 under Rosetta, plus its `wineserver`). Its processes
  must be left untouched during spike work; filter by our build path when cleaning up.
- zsh shadows `/usr/bin/log` with a builtin — use the absolute path.
