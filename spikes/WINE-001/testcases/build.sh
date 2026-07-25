#!/usr/bin/env bash
# WINE-001 guest testcase build script.
# Author: Tim Isaev
#
# jit_cross_view MUST be built with -Xclang -fasync-exceptions: without it
# clang only anchors SEH scopes at call sites and the __try guarding a faulting
# store silently loses its handler entry, so the rejection modes would report a
# dead process instead of a caught access violation.  See build-corpus.sh.
#
# Usage: build.sh <output-dir>   (toolchain must be on PATH)
set -euo pipefail
OUT=${1:?output dir required}
SRC=$(cd "$(dirname "$0")" && pwd)
CC=x86_64-w64-mingw32-clang

SEH_FLAGS=(-fms-extensions -Xclang -fasync-exceptions)

build() {
  local name=$1
  shift
  echo "cc $name"
  "$CC" -O2 -o "$OUT/$name.exe" "$SRC/$name.c" "$@"
}

# x64min has no CRT and no imports; its entry point is the first x64
# instruction, which is what makes it the loader gate (result 06).
build x64min -nostdlib -Wl,-e,entry
build x64hello
build jit_cross_view "${SEH_FLAGS[@]}"
echo wine-testcases-built
