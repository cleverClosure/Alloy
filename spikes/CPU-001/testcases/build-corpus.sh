#!/bin/bash
# CPU-001 guest corpus build script.
# Author: Timur Isaev
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
  # $2 carries per-test flag/lib lists; it MUST follow the source so that
  # import libraries (-luser32 -lgdi32) resolve — lld discards a -l listed
  # before the object that references it. Compile flags are position-neutral.
  # shellcheck disable=SC2086 # deliberate word-splitting of the flag/lib list
  "$CC" -O2 -o "$OUT/$1.exe" "$SRC/$1.c" $2
}

# x64hello is the WINE-001 first-execution smoke (spikes/WINE-001/testcases),
# not a CPU-001 corpus member; it is built by that spike's own flow.
build win_smoke "-luser32 -lgdi32"
build memory_semantics ""
build fault_cost ""
build noaccess_inventory ""
build jit_pages "-mavx2"
build isa_smoke "-msse4.2 -mavx2 -mbmi -mbmi2"
# Issue #104 systematic ISA corpus. SSE2 is the x86-64 baseline, so no -m flag
# is needed; the mutation-control variant is built by run-isa-corpus.sh and by
# build-isa-corpus-native.sh directly (not here), since it is a deliberately
# broken build that must never be the one shipped as "the corpus".
build isa_corpus_sse2 ""
# Vector breadth (issue #104, M3). Each clean binary has a separate native
# reference proof and deliberately corrupted build in verify-isa-vectors.py.
build isa_corpus_sse "-msse2 -ffp-contract=off -fno-fast-math"
build isa_corpus_sse3 "-msse3 -ffp-contract=off -fno-fast-math"
build isa_corpus_ssse3 "-mssse3 -ffp-contract=off -fno-fast-math"
build isa_corpus_sse41 "-msse4.1 -ffp-contract=off -fno-fast-math"
build isa_corpus_sse42 "-msse4.2 -ffp-contract=off -fno-fast-math"
build isa_corpus_avx "-mavx -ffp-contract=off -fno-fast-math"
build isa_corpus_avx2 "-mavx2 -ffp-contract=off -fno-fast-math"
build isa_corpus_bmi1 "-mbmi"
build isa_corpus_bmi2 "-mbmi2"
build isa_corpus_flags ""
build isa_corpus_atomics ""
# x87 is guest-side self-checked: never compiled as an arm64 FP oracle.
build isa_corpus_x87 "-ffp-contract=off -fno-fast-math"
build x87_fp_edge "-ffp-contract=off -fno-math-errno"
build cpu_throughput "-ffp-contract=off"
build cpu_scaling ""
build threads_tls ""
build guard_enforce ""
build exception_unwind "$SEH_FLAGS"
build seh_deep "$SEH_FLAGS"
build seh_concurrent "$SEH_FLAGS"
build seh_worker "$SEH_FLAGS"
build seh_multi "$SEH_FLAGS"
build seh_repeat "$SEH_FLAGS"
build seh_nullcall "$SEH_FLAGS"
# Census calibration guests (issues #12 and #37). census_probe proves the
# census counts decodes rather than executions; telemetry_probe calibrates the
# split flags against aligned and cross-boundary operations and guards the
# currently unsupported unaligned cmpxchg16b path.
build census_probe "-msse4.2"
build telemetry_probe "-mcx16"
# nullcall_probe (issue #20) reports what a VEH and an __except filter each
# receive for a guest branch into the null page, against a data-fault control
# that already worked. That separation is what located the defect in the SEH
# scope lookup rather than in dispatch.
build nullcall_probe "$SEH_FLAGS"
echo corpus-built
