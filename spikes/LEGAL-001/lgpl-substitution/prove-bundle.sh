#!/usr/bin/env bash
# LGPL-2.1 section 6 proof, built from the published bundle (counsel item 4).
# Author: Tim Isaev
#
# prove-substitution.sh showed that a modified library, once substituted, is
# what runs. It built that library from the lab's own Wine checkout, which a
# recipient does not have. This is the same proof from what a recipient does
# have: the corresponding-source bundle of a release, and nothing else of ours.
#
# It unpacks the bundle's Wine source, configures it with the arguments the
# bundle itself records, makes a deliberate modification, builds, ad-hoc signs,
# substitutes into a copy of the runtime, and launches a guest.
#
# The proof is falsifiable in both directions. The unmodified runtime runs first
# and must NOT show the marker; the substituted one must. A marker that appeared
# either way, or a harness that could not tell the two apart, would prove
# nothing.
#
# The runtime it is given is never changed: substitution happens in a copy.
#
# Usage: prove-bundle.sh <release-dir> <runtime-root> [work-dir]
#
#   release-dir   output of tools/release/make-release.sh
#   runtime-root  the Wine runtime that release ships
#   work-dir      kept for inspection when given; a temporary one otherwise
#
# By default the program launched is Wine's own cmd.exe, which needs nothing but
# the runtime. To launch something else, such as an x64 guest through FEX:
#
#   ALLOY_GUEST_EXE           the program
#   ALLOY_GUEST_EXPECT        a line it prints, required in both runs
#   ALLOY_GUEST_PREFIX        a prepared Wine prefix to copy for the run, when
#                             the program needs one (an emulator registered, say)
#   ALLOY_GUEST_DLLOVERRIDES  extra WINEDLLOVERRIDES entries, e.g. xtajit64=n
#
# Requires macOS on Apple silicon, and what the bundle names in BUILD-INPUTS.txt
# on PATH: the cross toolchain and bison 3. Takes a few minutes.
set -euo pipefail

RELEASE=${1:?release directory required}
RUNTIME=${2:?runtime root required}
WORK=${3:-}
GUEST=${ALLOY_GUEST_EXE:-}
EXPECT=${ALLOY_GUEST_EXPECT:-}

MARKER="ALLOY_LGPL_SUBSTITUTION_PROOF"
LIB=dlls/ntdll/ntdll.so
BUNDLE="$RELEASE/corresponding-source"

say() { printf '== %s\n' "$*"; }
die() { # exit-code message...
  local code=$1
  shift
  printf '%s\n' "$@" >&2
  exit "$code"
}

if [[ -z $WORK ]]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/alloy-bundle-proof.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
RELEASE=$(cd "$RELEASE" && pwd -P)
BUNDLE="$RELEASE/corresponding-source"
RUNTIME=$(cd "$RUNTIME" && pwd -P)

[[ -f $BUNDLE/wine/wine-src.tar.gz ]] || die 2 "no Wine source in the bundle: $BUNDLE"
[[ -f $RUNTIME/$LIB ]] || die 2 "no $LIB in the runtime: $RUNTIME"
if [[ -n $GUEST ]]; then
  [[ -f $GUEST ]] || die 2 "no guest executable: $GUEST"
  GUEST="$(cd "$(dirname "$GUEST")" && pwd -P)/$(basename "$GUEST")"
  GUEST_DIR=$(dirname "$GUEST")
  GUEST_ARGV=("$(basename "$GUEST")")
else
  # Wine's own shell: runs on the runtime alone, and says something we can
  # require, so "it launched" is observed rather than assumed.
  EXPECT=ALLOY_GUEST_RAN
  GUEST_DIR=$WORK
  GUEST_ARGV=(cmd.exe /c echo "$EXPECT")
fi

say "1. the bundle is intact"
(cd "$RELEASE" && shasum -a 256 -c SHA256SUMS >/dev/null) ||
  die 3 "SHA256SUMS does not verify: the bundle is not the one that was published"
echo "   $(wc -l <"$RELEASE/SHA256SUMS" | tr -d ' ') files verified"

say "2. unpack the source the bundle publishes"
rm -rf "$WORK/wine-src" "$WORK/wine-build"
tar -xzf "$BUNDLE/wine/wine-src.tar.gz" -C "$WORK"
[[ -x $WORK/wine-src/configure ]] || die 3 "the bundled source has no configure script"

say "3. make the deliberate modification"
python3 - "$WORK/wine-src/dlls/ntdll/unix/virtual.c" "$MARKER" <<'PY'
import sys
path, marker = sys.argv[1], sys.argv[2]
s = open(path).read()
anchor = "void virtual_init(void)\n{\n"
assert marker not in s, "the published source already carries the marker"
assert anchor in s, "virtual_init anchor not found - the source has moved"
s = s.replace(anchor, anchor + f'    ERR( "{marker} modified ntdll is live\\n" );\n', 1)
open(path, "w").write(s)
print("   marker inserted into virtual_init")
PY

say "4. configure as the bundle records"
# Read from the bundle, not from this repository: if the recorded arguments
# were wrong or missing, a recipient would be stuck exactly here.
ARGS=$(awk '/^wine configure arguments:/ { getline; sub(/^  /, ""); print; exit }' "$BUNDLE/BUILD-INPUTS.txt")
[[ -n $ARGS ]] || die 3 "BUILD-INPUTS.txt records no Wine configure arguments"
echo "   configure $ARGS"
mkdir -p "$WORK/wine-build"
# shellcheck disable=SC2086 # the recorded arguments are a list of words
(cd "$WORK/wine-build" && ../wine-src/configure $ARGS >"$WORK/configure.log" 2>&1) || {
  tail -20 "$WORK/configure.log" >&2
  die 4 "configure failed with the arguments the bundle records"
}

say "5. build the modified library from the bundled source"
make -C "$WORK/wine-build" -j"$(sysctl -n hw.ncpu)" "$LIB" >"$WORK/build.log" 2>&1 || {
  tail -20 "$WORK/build.log" >&2
  die 4 "build failed"
}
MOD_SHA=$(shasum -a 256 "$WORK/wine-build/$LIB" | awk '{print $1}')
BASE_SHA=$(shasum -a 256 "$RUNTIME/$LIB" | awk '{print $1}')
[[ $MOD_SHA != "$BASE_SHA" ]] || die 4 "the build is identical to the shipped library - the modification did not take"
echo "   shipped  $LIB $BASE_SHA"
echo "   modified $LIB $MOD_SHA"

say "6. copy the runtime; the one supplied is left as shipped"
rm -rf "$WORK/runtime" "$WORK/prefix"
cp -Rc "$RUNTIME" "$WORK/runtime" 2>/dev/null || cp -R "$RUNTIME" "$WORK/runtime"
if [[ -n ${ALLOY_GUEST_PREFIX:-} ]]; then
  cp -Rc "$ALLOY_GUEST_PREFIX" "$WORK/prefix" 2>/dev/null || cp -R "$ALLOY_GUEST_PREFIX" "$WORK/prefix"
fi

run_guest() { # log-file
  # Bounded with perl because macOS ships no timeout(1). The prefix is this
  # run's own, and mscoree/mshtml are disabled so creating it cannot stop to
  # offer a Mono or Gecko download that nobody is there to answer.
  (cd "$GUEST_DIR" && WINEPREFIX="$WORK/prefix" WINEDEBUG=fixme-all \
    WINEDLLOVERRIDES="mscoree,mshtml=${ALLOY_GUEST_DLLOVERRIDES:+;$ALLOY_GUEST_DLLOVERRIDES}" \
    DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib FEX_SILENTLOG=1 \
    perl -e 'alarm shift; exec @ARGV' 600 "$WORK/runtime/wine" "${GUEST_ARGV[@]}") >"$1" 2>&1 || true
  WINEPREFIX="$WORK/prefix" "$WORK/runtime/server/wineserver" -k >/dev/null 2>&1 || true
  WINEPREFIX="$WORK/prefix" "$WORK/runtime/server/wineserver" -w >/dev/null 2>&1 || true
}
hits() { grep -c "$MARKER" "$1" || true; }
guest_ok() { [[ -z $EXPECT ]] || grep -qF "$EXPECT" "$1"; }

say "7. control: the runtime as shipped must not show the modification"
run_guest "$WORK/control.log"
CONTROL=$(hits "$WORK/control.log")
if [[ $CONTROL != 0 ]]; then
  die 5 "the unmodified runtime printed the marker $CONTROL time(s) - this check cannot tell a substituted library from a shipped one"
fi
guest_ok "$WORK/control.log" || {
  tail -20 "$WORK/control.log" >&2
  die 5 "the guest did not run on the unmodified runtime, so nothing can be concluded from the substituted one"
}
echo "   marker absent; guest ran"

say "8. substitute and ad-hoc sign, as a recipient would"
cp -f "$WORK/wine-build/$LIB" "$WORK/runtime/$LIB"
codesign --force --sign - "$WORK/runtime/$LIB" >/dev/null 2>&1
# Captured, not piped into grep -q: grep exits at the first match, codesign
# dies writing to the closed pipe, and pipefail reports that as "not signed".
SIGNATURE=$(codesign -dv "$WORK/runtime/$LIB" 2>&1 || true)
[[ $SIGNATURE == *adhoc* ]] || die 6 "substituted library is not ad-hoc signed"
echo "   substituted and ad-hoc signed"

say "9. run, and require the modification to be observable"
run_guest "$WORK/modified.log"
MODIFIED=$(hits "$WORK/modified.log")
if [[ $MODIFIED == 0 ]]; then
  tail -20 "$WORK/modified.log" >&2
  die 7 "" "FAIL: the substituted library did not run. The modified-runtime path is" \
    "      blocked, which is an LGPL-2.1 section 6 problem, not a test problem."
fi
guest_ok "$WORK/modified.log" || {
  tail -20 "$WORK/modified.log" >&2
  die 7 "the modified library loaded, but the guest no longer runs"
}
[[ $(shasum -a 256 "$RUNTIME/$LIB" | awk '{print $1}') == "$BASE_SHA" ]] ||
  die 8 "the supplied runtime was modified - substitution must happen only in the copy"

say "PASS"
echo "   built from the bundle alone; marker absent as shipped, observed $MODIFIED time(s) once substituted"
echo "   the supplied runtime is unchanged"
