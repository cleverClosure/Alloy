#!/usr/bin/env bash
# LGPL-2.1 section 6 modified-runtime proof (counsel item 4).
# Author: Tim Isaev
#
# Builds a deliberately modified LGPL component from corresponding source,
# ad-hoc signs it as a recipient would, substitutes it into a runtime, and
# proves the modification is what actually executed.
#
# The proof is deliberately falsifiable. The modification prints a marker from
# virtual_init(), which every Wine process runs at startup, so the assertion is
# "the marker appeared" rather than "nothing complained". A substituted library
# that were silently ignored, overridden by a signed copy, or rejected by
# library validation would leave the marker absent and fail this script - which
# is the outcome that would mean we cannot ship.
#
# Usage: prove-substitution.sh <wine-source> <wine-build> <runtime-root> <guest-exe>
#
# Requires macOS on Apple silicon and the llvm-mingw toolchain on PATH; a
# GitHub-hosted runner cannot execute this (see README).
set -euo pipefail

SRC=${1:?wine source tree required}
BUILD=${2:?configured wine build directory required}
RUNTIME=${3:?runtime root to substitute into required}
GUEST=${4:?guest executable required}

MARKER="ALLOY_LGPL_SUBSTITUTION_PROOF"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

say() { printf '== %s\n' "$*"; }

say "1. record the unmodified library"
BASE_LIB=$BUILD/dlls/ntdll/ntdll.so
[[ -f $BASE_LIB ]] || {
  echo "no built ntdll.so at $BASE_LIB" >&2
  exit 2
}
cp -f "$BASE_LIB" "$WORK/ntdll.baseline.so"
BASE_SHA=$(shasum -a 256 "$WORK/ntdll.baseline.so" | awk '{print $1}')
echo "   baseline ntdll.so $BASE_SHA"

say "2. apply the deliberate modification to the LGPL source"
python3 - "$SRC/dlls/ntdll/unix/virtual.c" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
s = open(path).read()
anchor = "void virtual_init(void)\n{\n"
if marker in s:
    print("   already modified")
else:
    assert anchor in s, "virtual_init anchor not found - source has moved"
    s = s.replace(anchor, anchor + f'    ERR( "{marker} modified ntdll is live\\n" );\n', 1)
    open(path, "w").write(s)
    print("   marker inserted into virtual_init")
PY

say "3. build the modified library from corresponding source"
make -C "$BUILD" -j"$(sysctl -n hw.ncpu)" dlls/ntdll/ntdll.so >"$WORK/build.log" 2>&1 || {
  tail -20 "$WORK/build.log" >&2
  echo "build failed" >&2
  exit 3
}
MOD_SHA=$(shasum -a 256 "$BASE_LIB" | awk '{print $1}')
[[ $MOD_SHA != "$BASE_SHA" ]] || {
  echo "build produced an identical library - the modification did not take" >&2
  exit 4
}
cp -f "$BASE_LIB" "$WORK/ntdll.modified.so"
echo "   modified ntdll.so $MOD_SHA"

say "4. restore the source and the shared build tree"
python3 - "$SRC/dlls/ntdll/unix/virtual.c" "$MARKER" <<'PY'
import sys, re
path, marker = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'^ *ERR\( "' + re.escape(marker) + r'[^\n]*\n', '', s, flags=re.M)
open(path, "w").write(s)
PY
cp -f "$WORK/ntdll.baseline.so" "$BASE_LIB"

say "5. substitute and ad-hoc sign, as a recipient would"
cp -f "$WORK/ntdll.modified.so" "$RUNTIME/dlls/ntdll/ntdll.so"
codesign --force --sign - "$RUNTIME/dlls/ntdll/ntdll.so" >/dev/null 2>&1
# Captured, not piped into grep -q: grep exits at the first match, codesign
# dies writing to the closed pipe, and pipefail reports that as "not signed".
SIGNATURE=$(codesign -dv "$RUNTIME/dlls/ntdll/ntdll.so" 2>&1 || true)
[[ $SIGNATURE == *adhoc* ]] || {
  echo "substituted library is not ad-hoc signed" >&2
  exit 5
}
echo "   substituted and ad-hoc signed"

say "6. run, and require the modification to be observable"
LOG=$WORK/run.log
(cd "$(dirname "$GUEST")" && WINEDEBUG='+virtual' DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib \
  FEX_SILENTLOG=1 timeout 180 "$RUNTIME/wine" "$(basename "$GUEST")") >"$LOG" 2>&1 || true

HITS=$(grep -c "$MARKER" "$LOG" || true)
if [[ ${HITS:-0} -eq 0 ]]; then
  echo >&2
  echo "FAIL: the substituted library did not run. The modified-runtime path is" >&2
  echo "      blocked, which is an LGPL-2.1 section 6 problem, not a test problem." >&2
  tail -20 "$LOG" >&2
  exit 6
fi

say "PASS"
echo "   modification observed $HITS times; the substituted LGPL library is what executed"
echo "   baseline $BASE_SHA"
echo "   modified $MOD_SHA"
