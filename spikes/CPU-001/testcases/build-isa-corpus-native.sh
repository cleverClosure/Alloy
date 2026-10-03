#!/usr/bin/env bash
# CPU-001 ISA-corpus native oracle check (issue #104, Milestone 1).
# Author: Tim Isaev
#
# isa_corpus_sse2.c compiles two ways: as the x64 Windows PE guest (built by
# build-corpus.sh; real SSE2 instructions checked against the portable C
# reference) and, here, natively for this host's arm64 - there is no real
# SSE2 to check on this CPU, so only the portable reference side runs. This
# script is the Milestone 1 proof that the reference path is trustworthy
# *before* any translator is involved:
#
#   - it must reproduce byte-identical output across -O0/-O1/-O2/-O3 (an
#     optimisation-level disagreement would mean the reference reads
#     something undefined, which a fixed seed alone cannot catch);
#   - it must reproduce byte-identical output across three separate
#     invocations of the same binary (determinism, not just reproducibility);
#   - its hand-computed vectors (checked inside the program itself, see
#     run_hand_vectors() in the source) must pass.
#
# Pass extra cflags, most usefully -DALLOY_CORPUS_MUTATE_PADDB, to build the
# deliberately-broken negative control instead: that build must FAIL (see
# "mutate" below) and is expected to differ from the clean checksum.
#
# Usage: build-isa-corpus-native.sh <output-dir> [extra cflags...]
set -euo pipefail

OUT=${1:?output dir required}
shift || true
SRC=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"

# Deliberately NOT a bare "clang" lookup, and deliberately not "xcrun -f
# clang" either. The cross toolchain's own bin/clang is a plain upstream build
# with no macOS SDK auto-detection, so once it is ahead of Apple's on PATH
# (exactly what building the x64 guest, or tools/lint.sh, asks for) a bare
# "clang" silently compiles for this host anyway but cannot find <stdio.h> -
# fails loud, but easy to misread as a missing SDK rather than the wrong
# compiler. "xcrun -f clang" does not consult PATH at all - it resolves to
# Xcode's own clang - but invoking that resolved path directly has the same
# problem for a different reason: going around /usr/bin/clang skips its
# SDK-root auto-injection regardless of which binary sits at the resolved
# path. /usr/bin/clang is the stable wrapper that finds its SDK regardless of
# PATH or working directory; verified against both failure modes before
# relying on it (see the results doc).
CC=/usr/bin/clang

mutate=clean
for arg in "$@"; do
  [[ $arg == -DALLOY_CORPUS_MUTATE_* ]] && mutate=${arg#-DALLOY_CORPUS_MUTATE_}
done
# Lower-cased so it matches the op-table name the program itself prints
# (e.g. mutate=PADDB -> op_tag=paddb), used below to confirm a FAIL line
# actually names the operation this build was supposed to break.
op_tag=$(printf '%s' "$mutate" | tr '[:upper:]' '[:lower:]')

for opt in O0 O1 O2 O3; do
  echo "cc -$opt $*"
  "$CC" -std=c11 -Wall -Wextra -"$opt" "$@" \
    -o "$OUT/isa_corpus_sse2.$mutate.$opt" "$SRC/isa_corpus_sse2.c"
done

first=
for opt in O0 O1 O2 O3; do
  bin="$OUT/isa_corpus_sse2.$mutate.$opt"
  log="$OUT/native-$mutate-$opt.log"
  set +e
  "$bin" >"$log" 2>&1
  rc=$?
  set -e
  printf 'run -%s: exit=%d\n' "$opt" "$rc"

  # Pass/fail here must not rest on the program's own failure counter alone -
  # a single missed g_fail_count++ among its ~50 call sites would otherwise
  # print an explicit FAIL line and still exit 0, and nothing would notice.
  # So exit code and the FAIL lines the program printed are checked
  # independently of each other, and independently of that counter.
  if [[ $mutate == clean ]]; then
    if [[ $rc != 0 ]]; then
      echo "clean build at -$opt exited $rc, expected 0 (no reference is supposed to be broken)" >&2
      exit 1
    fi
    if grep -q '^FAIL' "$log"; then
      echo "clean build at -$opt exited 0 but printed a FAIL line - exit code alone was not enough evidence:" >&2
      grep '^FAIL' "$log" >&2
      exit 1
    fi
  else
    if [[ $rc == 0 ]]; then
      echo "mutate=$mutate build at -$opt exited 0 - the corruption must be detected" >&2
      exit 1
    fi
    if ! grep -qi "FAIL.*$op_tag" "$log"; then
      echo "mutate=$mutate build at -$opt exited $rc but never printed a FAIL line naming $op_tag - a nonzero exit alone is not evidence the corruption itself was caught" >&2
      exit 1
    fi
  fi

  if [[ -z $first ]]; then
    first=$log
  elif ! cmp -s "$first" "$log"; then
    echo "native output differs between optimization levels: $first vs $log" >&2
    diff "$first" "$log" >&2 || true
    exit 1
  fi
done
echo "agrees across -O0/-O1/-O2/-O3"

# Reproducibility: the SAME optimized binary, three separate invocations.
for n in 1 2 3; do
  "$OUT/isa_corpus_sse2.$mutate.O2" >"$OUT/repro-$mutate-$n.log" 2>&1 || true
done
if ! cmp -s "$OUT/repro-$mutate-1.log" "$OUT/repro-$mutate-2.log" ||
  ! cmp -s "$OUT/repro-$mutate-2.log" "$OUT/repro-$mutate-3.log"; then
  echo "native output differs across repeated invocations of the same binary" >&2
  exit 1
fi
echo "byte-identical across 3 separate invocations"

cp "$OUT/repro-$mutate-1.log" "$OUT/native-oracle-$mutate.log"
tail -n1 "$OUT/native-oracle-$mutate.log"
