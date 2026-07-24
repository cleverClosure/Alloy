#!/bin/bash
# CPU-001 guest corpus build script.
# Author: Tim Isaev
#
# __try/__except tests MUST be built with -Xclang -fasync-exceptions: without
# it clang only anchors SEH scopes at call sites, so a __try guarding a bare
# faulting instruction silently loses its handler entry (no .xdata scope) and
# the exe can never catch hardware faults - the runtime then correctly reports
# the exception unhandled. This cost result 08 its dispatch-defect attribution.
#
# Usage: build-corpus.sh <output-dir>   (toolchain must be on PATH)
set -e
OUT=${1:?output dir required}
SRC=$(cd "$(dirname "$0")" && pwd)
CC=x86_64-w64-mingw32-clang

SEH_FLAGS="-fms-extensions -Xclang -fasync-exceptions"

build() {
  echo "cc $1"
  # shellcheck disable=SC2086 # $2 carries per-test flag lists
  "$CC" -O2 $2 -o "$OUT/$1.exe" "$SRC/$1.c"
}

build x64hello ""
build win_smoke ""
build memory_semantics ""
build fault_cost ""
build noaccess_inventory ""
build jit_pages ""
build isa_smoke "-msse4.2 -mavx2 -mbmi -mbmi2"
build x87_fp_edge ""
build threads_tls ""
build guard_enforce ""
build exception_unwind "$SEH_FLAGS"
build seh_deep "$SEH_FLAGS"
build seh_concurrent "$SEH_FLAGS"
build seh_worker "$SEH_FLAGS"
build seh_multi "$SEH_FLAGS"
echo corpus-built
