# Darwin JIT signal resume

Author: Timur Isaev

Issue #111 repairs Wine's implicit switch from writable JIT memory to executable
JIT memory on macOS 27.0 (26A428). The old handler calls
`pthread_jit_write_protect_np(1)` and returns to the faulting instruction. On the
measured host, execution works inside that handler but faults again after its
return. An ordinary system call and a signal delivered while execution is already
enabled both succeed. This is a measured signal-transition failure; no claim is
made that the same native reproducer was run on macOS 26.

The [pthread API](https://github.com/apple-oss-distributions/libpthread/blob/main/include/pthread/pthread.h)
changes JIT protection per thread. The repair uses that public API after the
original fault handler returns, then restores the interrupted state through a
fresh `SIGUSR2` context. Wine already uses `SIGUSR2` for full context restoration.
The kernel performs both ordinary signal returns. There is no replacement
`sigreturn` implementation or private hardware-register write.

Each thread allocates its resume context and a separate stack before handling
signals. Guard pages bound that stack and separate it from the saved context.
During the transition, asynchronous signals stay blocked until JIT execution is
enabled; the fresh signal restores the original mask, alternate-stack state,
registers and stack pointer. The guest's stack and red zone are preserved.
Existing guest write-protection checks and translated-store emulation remain in
place. Only executable JIT views request this resume path.

## Native regression proof

```sh
python3 spikes/WINE-001/jit-signal/run-native.py
# Or through the full-tier registry:
python3 tools/test-all --only wine-jit-signal-native
```

The test extracts the actual new header from `wine.patch`, verifies it matches
the reviewable header here, and compiles that extracted implementation. It checks
30 general registers, all 32 SIMD registers, SP, NZCV, FPCR/FPSR and the 128-byte
red zone. Darwin's reserved x18 is copied from the saved signal context but is
excluded from the register-preservation assertion because Darwin clears it on
kernel entry.

Controls cover direct execution with zero faults, the old bounded four-fault
loop, successful resumption, an originally blocked `SIGUSR2`, a fault inside an
alternate-stack handler, and 512 resumes across eight threads. Deliberately
corrupting x9 or v15 must fail only the corresponding named state check. Every
process has a finite timeout. Reports and binaries go under the gitignored
`spikes/WINE-001/work/jit-signal-runs/`. This proof does not execute Wine or claim
FEX correctness; the dated CPU-001 runtime report records those separate runs.

## Applying the fork patch in isolation

`wine.patch` applies to the existing Alloy Wine fork at
`420c70bdcb7615c3dc0395d162f93645f098fe56`. The verified private source commit is
`f0937d595166631dd00eaab31fef4fb5a6f37031`. The patch contains the header and both
Wine integration edits. Its native regression suite needs only Apple clang and
Python; no FEX source change or new dependency is required.

Start from a fresh private checkout of that committed Wine base and an APFS copy
of the already-built runtime. Keep the shared source branch and `build-2` intact.
Set `wine_source`, `wine_build` and `alloy_repo` to absolute paths for those two
**private** directories and this Alloy checkout, then run:

```sh
git -C "$wine_source" switch -c alloy/task-111-macos27-runtime
git -C "$wine_source" apply --check "$alloy_repo/spikes/WINE-001/jit-signal/wine.patch"
git -C "$wine_source" apply "$alloy_repo/spikes/WINE-001/jit-signal/wine.patch"

# Reconfigure the copied build: its old Makefile still names shared sources.
export PATH="$alloy_repo/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH"
cd "$wine_build"
CFLAGS='-g -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' \
  "$wine_source/configure" --with-mingw --without-x --enable-archs=arm64ec,aarch64
# Verify Makefile's srcdir points to the private source before building.
rg '^srcdir =' Makefile
make -j4 dlls/ntdll/ntdll.so
```

Only `ntdll.so` is rebuilt. The loader, server, PE modules and builtin FEX remain
from the copied runtime. Record their hashes, the complete runtime inventory,
and the Wine/FEX source identities before and after guest verification. Wine
loads its builtin `libarm64ecfex.dll`; a prefix copy does not select the emulator.

The #104 standing corpus command accepts this already-built runtime through
`--wine-build`, `--wine-source` and `--fex-source`. It writes only a separate
scratch prefix and reports every clean/mutated result. The shared runtime has
not been promoted or replaced by this repair.
