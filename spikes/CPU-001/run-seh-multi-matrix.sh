#!/usr/bin/env bash
# Capture the CPU-001 multi-worker exception matrix with FEX breadcrumbs.
# Author: Timur Isaev

set -euo pipefail

usage() {
  echo "usage: $0 <fex-dll> <wine-loader> <wine-prefix> <guest-dir> [runs]" >&2
}

if (($# < 4 || $# > 5)); then
  usage
  exit 2
fi

fex_dll=$1
wine_loader=$2
wine_prefix=$3
guest_dir=$4
runs=${5:-1}

if [[ ! $runs =~ ^[1-9][0-9]*$ ]]; then
  echo "runs must be a positive integer" >&2
  exit 2
fi

for file in "$fex_dll" "$wine_loader"; do
  if [[ ! -f $file ]]; then
    echo "missing required file: $file" >&2
    exit 2
  fi
done
for dir in "$wine_prefix" "$guest_dir"; do
  if [[ ! -d $dir ]]; then
    echo "missing required directory: $dir" >&2
    exit 2
  fi
done

fex_dll=$(cd "$(dirname "$fex_dll")" && pwd)/$(basename "$fex_dll")
wine_loader=$(cd "$(dirname "$wine_loader")" && pwd)/$(basename "$wine_loader")
wine_prefix=$(cd "$wine_prefix" && pwd)
guest_dir=$(cd "$guest_dir" && pwd)

script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
llvm_readobj=${LLVM_READOBJ:-"$repo_root/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin/llvm-readobj"}
installed_fex="$wine_prefix/drive_c/windows/system32/libarm64ecfex.dll"
guest_exe="$guest_dir/seh_multi.exe"

for file in "$fex_dll" "$wine_loader" "$llvm_readobj" "$guest_exe"; do
  if [[ ! -f $file ]]; then
    echo "missing required file: $file" >&2
    exit 2
  fi
done
if [[ ! -x $wine_loader ]]; then
  echo "Wine loader is not executable: $wine_loader" >&2
  exit 2
fi
if [[ ! -d $(dirname "$installed_fex") ]]; then
  echo "Wine prefix is not initialized: $wine_prefix" >&2
  exit 2
fi
if ! "$llvm_readobj" --coff-exports "$fex_dll" | rg -q 'Name: FEXWineLogSink$'; then
  echo "FEX DLL does not export the required writable FEXWineLogSink data slot" >&2
  exit 2
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
output_dir="$guest_dir/logs/seh-multi-sink-$timestamp"
summary="$output_dir/summary.tsv"
mkdir -p "$output_dir"

cp "$fex_dll" "$installed_fex"
if ! cmp -s "$fex_dll" "$installed_fex"; then
  echo "installed FEX DLL does not match the requested input" >&2
  exit 2
fi

{
  echo "fex_source_sha256"
  shasum -a 256 "$fex_dll"
  echo "fex_installed_sha256"
  shasum -a 256 "$installed_fex"
  echo "wine_loader"
  echo "$wine_loader"
  echo "wine_prefix"
  echo "$wine_prefix"
} >"$output_dir/inputs.txt"

printf 'mode\trun\texit\tcaught\tbreadcrumbs\tlog\n' >"$summary"

wine_debug=${WINEDEBUG:-warn+debugstr}
dyld_fallback=${DYLD_FALLBACK_LIBRARY_PATH:-/opt/homebrew/lib}
failed=0
modes=(simultaneous staggered sequential warmup)

for mode in "${modes[@]}"; do
  for ((run = 1; run <= runs; run++)); do
    log="$output_dir/${mode}-${run}.log"
    set +e
    (
      cd "$guest_dir"
      env \
        WINEPREFIX="$wine_prefix" \
        WINEDLLOVERRIDES=xtajit64=n \
        WINEDEBUG="$wine_debug" \
        DYLD_FALLBACK_LIBRARY_PATH="$dyld_fallback" \
        FEX_SILENTLOG=0 \
        "$wine_loader" seh_multi.exe "$mode"
    ) >"$log" 2>&1
    rc=$?
    set -e

    caught=$(rg -o '[0-9]+/4 caught' "$log" | tail -n 1 || true)
    caught=${caught:-none}
    breadcrumbs=$(rg -c \
      'Exception: Code:|Rethrowing onto guest stack|SyncThreadContext|ProcessPendingCrossProcessEmulatorWork|RethrowGuestException' \
      "$log" 2>/dev/null || true)
    breadcrumbs=${breadcrumbs:-0}
    printf '%s\t%d\t%d\t%s\t%s\t%s\n' \
      "$mode" "$run" "$rc" "$caught" "$breadcrumbs" "$log" | tee -a "$summary"
    if ((rc != 0)); then
      failed=1
    fi
  done
done

echo "capture: $output_dir"
exit "$failed"
