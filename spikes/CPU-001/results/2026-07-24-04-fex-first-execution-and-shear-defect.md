# CPU-001 result 04 — real FEX executes the x64 smoke corpus under Wine on macOS

**Author:** Tim Isaev
**Date:** 24 July 2026
**FEX revision:** 0589d9b (darwin-teb build variant, tree unmodified) ·
**Wine:** `alloy/spike-wine-001` @ `47e4cdb` (WINE-001 build-2) ·
**Hardware:** MacBook Pro M2 Pro, 16 GB, macOS 26.5

## Outcome

**The real FEX emulator runs x64 Windows programs under EC Wine on macOS.** With
`libarm64ecfex.dll` (darwin-teb variant) installed in a dedicated prefix and selected via
`HKLM\Software\Microsoft\Wow64\amd64`, five x64 PE guests execute end-to-end:

| Guest | Exit | Proves |
| --- | --- | --- |
| `x64hello.exe` | 0 | Full CRT boot, TLS callbacks, stdio through the emulator |
| `isa_smoke.exe` | 0 | CPUID advertises SSE4.2/OSXSAVE/AVX/AVX2/BMI1/BMI2; XCR0 AVX state; CRC32C, ANDN/BLSI, PDEP/PEXT, AVX2 lane math all match bit-exact references |
| `exception_unwind.exe` | 0 | `RaiseException` with arguments, `ud2` resume, null-AV resume with RIP advance, `PAGE_GUARD` violation, 9-frame `RtlCaptureStackBackTrace`, `longjmp`, native→guest `EnumSystemLocalesEx` callbacks |
| `memory_semantics.exe` | 0 | 4×250k interlocked increments, CAS loops, `cmpxchg16b` success+failure, `lock xadd` across a cache line **and a 4 KB page boundary**, 200k-iteration store-order handshake |
| `jit_pages.exe` | **7** | W^X RW↔RX transitions + code invalidation, code straddling guest-4K and host-16K boundaries, RX write rejection all pass — then **fails: interior 4 KB `PAGE_NOACCESS` is not enforced** (see below) |

The AVX2/BMI/SSE4.2 result closes the portfolio's hard boot-gate requirement (FF VII
Rebirth and FF XVI refuse to start without AVX2; Yakuza needs AVX+SSE4.2 — catalog §7.0).

## The darwin-teb build: x18 root cause and a build-input-only fix

The canonical-flag DLL from result 03 dies at runtime: lldb (logs
`lldb-x18-*.log`) catches `ldr x8, [x18, #0x60]` at DLL+0x18d2d0 with a **valid TEB pointer
in x18 at the breakpoint**, then `EXC_BAD_ACCESS address=0x60` when the instruction actually
executes — the kernel zeroed x18 in between. Same Darwin behavior WINE-001 gate 2 proved for
Wine itself: **x18 does not survive kernel entries on macOS**, so ARM64EC's x18=TEB register
convention is unusable in compiled code.

Fix (zero FEX source changes, config only — compatible with the FEX no-AI-contribution
boundary since nothing here is FEX-authored code):

- `-ffixed-x18` — the compiler never allocates or reads x18;
- `-I …/darwin-teb-overlay` — shadows toolchain `winnt.h` with WINE-001's patched one, so
  every `NtCurrentTeb()` compiles to the pthread-TSD-slot-6 read (`tpidrro_el0`-based)
  instead of `__getReg(18)`.

Both builds are 5,140,480 bytes; canonical `f24fd501…`, darwin-teb `0a1c3d39…` (installed in
the probe prefix). All corpus results above are from the darwin-teb DLL.

Open question deliberately left un-probed: FEX's **JIT-emitted** code and hand-written
dispatchers may still reference x18 on paths the smoke corpus does not reach. The corpus
passing means the hot paths compiled from C++ are clean; a fuller corpus run remains the
test.

## UnixLib status: not present, and not needed for correctness so far

FEX's PE side discovers its unix-side library two ways
(`Source/Windows/Common/FEXUnixLib.cpp`): `MemoryWineLoadUnixLibByName` and the legacy
`MemoryWineUnixFuncs`. Both fail cleanly here (no Darwin `.so` exists), so
`UnixLibAvailable()` is false and every control degrades to its fallback: hardware TSO
enable falls to the Proton-only `ProcessFexHardwareTso` info class, which our Wine does not
implement → **FEX runs with its own explicit barrier/atomic emission**.
`memory_semantics.exe` passing (including the 200k store-order handshake and page-crossing
locked RMW) is the evidence that this software-TSO path is correct. macOS has no public
hardware-TSO toggle, so explicit barriers are the working baseline; their cost is a later
measurement, not a correctness gate. A prepared 6-entry stub
(`work/darwin-teb-overlay/fex_unixlib_darwin.cpp`) exists for when madvise/VMA controls
become worth wiring.

## The one red result: 4 KB sub-page protection is silently unenforced (page shear)

The failing scenario, minimal: commit 64 KB RW → `VirtualProtect(base+0x1000, 0x1000,
PAGE_NOACCESS)` succeeds → guest reads `base+0x1000` → **no fault, read returns data**.
Pre-restore diagnostics added today make the split exact:

```text
4 KB subpage: protected guest read did not fault; handled delta=0
4 KB subpage: pre-restore VirtualQuery base=0000000108FC1000 size=00001000 state=00001000 protect=00000001
```

`VirtualQuery` reports exactly one 4 KB page, `MEM_COMMIT`, `PAGE_NOACCESS` (0x01):
**Wine's per-guest-page bookkeeping is fully correct; only hardware enforcement is
missing.** Mechanism: the host page is 16 KB; `get_host_page_vprot` ORs the four guest
vprots into the host protection, so most-permissive wins and an interior NOACCESS page
never traps.

Why the other protection tests pass — and the general law:

- `exception_unwind`'s guard page worked because its 4 KB page sat **alone** in its host
  page (the rest of that 64 KB allocation was uncommitted) → union = guard.
- RX write rejection worked because the **whole region** shared one protection.
- Enforcement is correct exactly when a host page is protection-homogeneous, and silently
  most-permissive when it is not. Rosetta/CrossOver never see this (x86_64 processes get
  4 KB host pages); the native-ARM64 path is uniquely exposed.

Real-software exposure (to be cataloged, not assumed): app-managed guard pages inside
committed spans, GC write barriers via protection (e.g. .NET), anti-tamper page tricks
(Denuvo — P5R is the only Denuvo core title), allocator redzones. Wine-owned thread-stack
guard regions are allocated by Wine itself and can be host-page-aligned, so stack overflow
detection is recoverable regardless.

Candidate strategies for the gate-4 design decision (feeds ADR-0005 or a fork ADR):

1. **Restrictive union + sibling emulation** — AND the vprots, then absorb the spurious
   faults from legitimately-accessible sibling pages in `segv_handler` (emulate or flip
   protection windows). Correct; hot-page cost unknown and must be measured first.
2. **Accept coarse enforcement** — align Wine-owned guards to 16 KB, ship, and catalog
   which portfolio titles actually depend on interior sub-page protection before paying
   for (1).
3. **Hybrid** — track a per-host-page "sheared" flag; only sheared pages take the
   restrictive-union slow path. Likely end-state; strictly more machinery than (2).

Recommendation recorded here: start with (2)'s catalog plus a micro-benchmark of (1)'s
fault cost, then decide; (3) only with data.

## Watch items (absorbed, non-fatal, single digits per process)

- Once per guest thread: absorbed AV at `addr 0x7ffx…808`, `pc` = FEX DLL+0x1018,
  `lr` +0x1234 — looks like an early TEB/CPU-area probe against a not-yet-mapped page.
  Founder-side root cause in FEX when convenient; harmless today.
- Up to twice per Wine process (services included, FEX not involved): absorbed AV at
  `addr 0x30`, low-VA `pc` ending `…9ec`. Pre-dates FEX in this prefix; Wine-side; watch.
- No fault storms in any run — the WINE-001 storm detector stayed quiet; the absorbed-fault
  counters above are its output doing exactly what it was kept for.

## Runbook

```sh
TC=tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin
# guest tests (x64 PE): flags per test — AVX2/BMI tests need the ISA switches
$TC/x86_64-w64-mingw32-clang -O2 -mavx2 -o jit_pages.exe testcases/jit_pages.c
$TC/x86_64-w64-mingw32-clang -O2 -msse4.2 -mavx2 -mbmi -mbmi2 -o isa_smoke.exe testcases/isa_smoke.c

# prefix: wineboot, then select FEX and install the DLL
wine regedit select-fex.reg            # HKLM\Software\Microsoft\Wow64\amd64 = libarm64ecfex.dll
cp build-arm64ec-darwin-teb/Bin/libarm64ecfex.dll prefix/drive_c/windows/system32/

WINEPREFIX=$PWD/prefix WINEDLLOVERRIDES=xtajit64=n WINEDEBUG=warn+debugstr \
  ../../WINE-001/work/build-2/loader/wine isa_smoke.exe
```

Logs from today's verification runs: `work/fex-runtime-probe/logs/rerun-*.log`.

## Verdict and next

Spike gates: **gate 2 (host abstractions) has no open correctness item on the paths
exercised; gate 3 is green at smoke scope; gate 4 (mixed process) has first light** — real
FEX, real Wine, one process, both architectures. The existential question has moved from
"does FEX run on macOS at all" to a bounded engineering decision: **sub-page protection
under 16 KB shear is the top open CPU-001 defect.**

1. Shear strategy: build the title-dependence catalog and measure restrictive-union fault
   cost; then decide 1/2/3 above and record it as an ADR.
2. Run FEX's full instruction-correctness corpus (gate 3 at full scope) in this prefix.
3. Founder: root-cause the per-thread DLL+0x1018 probe fault; wire the Darwin UnixLib only
   when its controls start mattering.
4. First CPU-overhead measurement once a game-shaped workload exists (gate 5 entry).
