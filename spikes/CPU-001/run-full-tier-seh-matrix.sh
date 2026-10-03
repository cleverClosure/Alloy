#!/usr/bin/env bash
# tools/test-all's full-tier wrapper around run-seh-multi-matrix.sh.
# Author: Tim Isaev
#
# run-seh-multi-matrix.sh (this spike's own script) takes four
# already-prepared inputs as positional arguments: a FEX DLL, a Wine loader,
# an initialized prefix, and a guest directory holding seh_multi.exe. None of
# that exists on a bare checkout, and per TASKS.md none of it may be written
# under the shared build tree itself. This wrapper supplies all four from
# ALLOY_WINE_BUILD (read-only) plus a scratch area local to this checkout,
# builds the guest corpus fresh each run, boots its own prefix only once
# (reused on later runs - a cold wineboot is the slow part), and then
# delegates to the real script unchanged.
#
# Usage: run-full-tier-seh-matrix.sh <work-dir>
#   ALLOY_WINE_BUILD   configured Wine build tree (required, no default - see
#                      tools/test-all's need_wine_build probe)
set -euo pipefail

usage() {
  echo "usage: $0 <work-dir>" >&2
}

if (($# != 1)); then
  usage
  exit 2
fi

work_root=$1
here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
toolchain_bin=$(dirname "$(command -v x86_64-w64-mingw32-clang)")

wine_build=${ALLOY_WINE_BUILD:?ALLOY_WINE_BUILD is required}
fex_dll="$wine_build/dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
wine_loader="$wine_build/wine"

case "$work_root" in
  "$repo_root"/spikes/CPU-001/work/*) ;;
  *)
    echo "work-dir must stay under $repo_root/spikes/CPU-001/work/ (gitignored scratch)" >&2
    exit 2
    ;;
esac

guest_dir="$work_root/guest"
prefix="$work_root/prefix"
mkdir -p "$guest_dir" "$prefix"

export PATH="$toolchain_bin:$PATH"
# run-seh-multi-matrix.sh defaults LLVM_READOBJ to a path under this repo's
# own tools/toolchains/, which does not exist in a worktree (gitignored, only
# the primary checkout has it). Point it at whatever PATH just resolved so
# the override always matches the compiler we built the corpus with.
export LLVM_READOBJ="$toolchain_bin/llvm-readobj"

bash "$here/testcases/build-corpus.sh" "$guest_dir" >"$work_root/build-corpus.log" 2>&1

run_wine() {
  perl -e 'alarm shift; exec @ARGV' 120 env \
    PATH="$toolchain_bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WINEPREFIX="$prefix" \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    WINEDEBUG=-all \
    "$wine_loader" "$@"
}

if [[ ! -d "$prefix/drive_c/windows/system32" ]]; then
  # mscoree,mshtml= so a fresh prefix never stalls offering a Mono/Gecko
  # download (TASKS.md's own Wine-launch rule); a finite alarm so a stuck
  # installer prompt fails this step instead of eating the whole suite
  # timeout silently.
  run_wine wineboot -u >"$work_root/wineboot.log" 2>&1

  # "A Wine prefix with the emulator registered" (issue #100 milestone 3) is
  # this key: without it Wow64 looks for amd64 CPU emulation under the name
  # xtajit64.dll and a fresh prefix's placeholder for that name is not a
  # loadable image (status c0000135), so every guest fails before main() runs.
  # launch-deus-ex-mankind-divided.sh registers the same key the same way.
  select_fex_reg="$work_root/select-fex.reg"
  printf '%s\n' \
    'REGEDIT4' \
    '' \
    '[HKEY_LOCAL_MACHINE\Software\Microsoft\Wow64\amd64]' \
    '@="libarm64ecfex.dll"' \
    >"$select_fex_reg"
  run_wine regedit "$select_fex_reg" >"$work_root/regedit.log" 2>&1
fi

stop_server() {
  # Only ever our own prefix's server - never build-2's.
  env WINEPREFIX="$prefix" "$wine_build/server/wineserver" -k >/dev/null 2>&1 || true
}
trap stop_server EXIT

bash "$here/run-seh-multi-matrix.sh" "$fex_dll" "$wine_loader" "$prefix" "$guest_dir" 1
