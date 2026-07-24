#!/usr/bin/env bash
# Build the M12-005 x64 D3D12 reference scene.
# Author: Timur Isaev
set -euo pipefail

scene_root="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$scene_root/../../.." && pwd)"
toolchain_bin="$repo_root/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin"
compiler="$toolchain_bin/x86_64-w64-mingw32-clang"
work_dir="$repo_root/spikes/M12-005/work"

if [[ ! -x "$compiler" ]]; then
  printf 'missing pinned llvm-mingw compiler; run tools/fetch-deps.sh\n' >&2
  exit 1
fi

mkdir -p "$work_dir"

"$compiler" \
  -std=c11 -O2 -Wall -Wextra -Werror \
  "$scene_root/d3d12_reference.c" \
  -o "$work_dir/d3d12_reference.exe" \
  -ld3d12 -ldxgi -ld3dcompiler -ldxguid -luuid -lole32 -luser32 -lgdi32

file "$work_dir/d3d12_reference.exe"
