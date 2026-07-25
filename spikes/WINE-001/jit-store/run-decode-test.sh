#!/usr/bin/env bash
# Build and run the ARM64 translated-JIT store decoder unit test.
# Author: Tim Isaev
#
# The decoder under test is the header ntdll actually ships.  It is included
# from the Wine tree by -I rather than copied here on purpose: a copy is free
# to drift from the shipped decoder, and the first one did.
#
# Usage: run-decode-test.sh [wine-source-dir]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../../.." && pwd)
wine_src=${1:-${ALLOY_WINE_SOURCE:-$repo_root/third_party/src/wine}}
header_dir=$wine_src/dlls/ntdll/unix
header=$header_dir/arm64_jit_store.h

if [[ ! -f $header ]]; then
  echo "error: shipped decoder not found at $header" >&2
  echo "       pass the Wine source directory as the first argument" >&2
  exit 2
fi

out=${TMPDIR:-/tmp}/alloy-decode-test.$$
trap 'rm -f "$out"' EXIT

cc -std=c11 -O2 -Wall -Wextra -Werror -I "$header_dir" -o "$out" "$here/decode-test.c"
"$out"
