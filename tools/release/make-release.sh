#!/usr/bin/env bash
# Minimal release pipeline: versioned artifact + corresponding-source bundle.
# Author: Tim Isaev
#
# LGPL-2.1 section 6 requires that a recipient be able to rebuild and substitute
# the LGPL components. PR #43 proved substitution works; this produces the other
# half - the corresponding source that makes substitution *possible* for someone
# who has only the binary. Neither half discharges the obligation alone.
#
# Every LGPL component must be either bundled with its corresponding source or
# recorded as an explicit gap. A bundle that silently omits a component is worse
# than no bundle: it looks like compliance.
#
# Runs on macOS/Apple silicon against the lab Wine build tree. A hosted GitHub
# runner cannot do this (see spikes/LEGAL-001/lgpl-substitution/README.md).
#
# Usage: make-release.sh <version> <out-dir> <wine-src> <fex-src> [dxmt-src]
set -euo pipefail

VERSION=${1:?version required, e.g. 0.1.0-lab}
OUT=${2:?output directory required}
WINESRC=${3:?wine source tree required}
FEXSRC=${4:?fex source tree required}
DXMTSRC=${5:-}

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BUNDLE="$OUT/corresponding-source"

say() { printf '== %s\n' "$*"; }
gap() {
  printf '   GAP: %s\n' "$*"
  GAPS+=("$1")
}
GAPS=()

rm -rf "$OUT"
mkdir -p "$BUNDLE"

# --- one LGPL component -----------------------------------------------------
# Bundles the fork source as a git archive plus the diff against its upstream
# base, because "here is our tree" and "here is what we changed" answer
# different questions and section 6 wants both.
bundle_component() { # name src-dir licence elected-version upstream-ref
  local name=$1 src=$2 licence=$3 elected=$4 upstream=${5:-}
  local d="$BUNDLE/$name"

  if [[ ! -d $src/.git ]]; then
    gap "$name: no source tree at $src - corresponding source NOT bundled"
    return
  fi
  mkdir -p "$d"

  local rev
  rev=$(git -C "$src" rev-parse HEAD)
  git -C "$src" archive --format=tar "$rev" | gzip >"$d/$name-src.tar.gz"

  if [[ -n $upstream ]] && git -C "$src" rev-parse --verify -q "$upstream" >/dev/null; then
    git -C "$src" diff "$upstream".."$rev" >"$d/$name-fork.patch" || true
    printf '%s\n' "$upstream" >"$d/UPSTREAM-BASE"
  else
    gap "$name: no upstream base recorded - the fork diff cannot be produced"
  fi

  cat >"$d/COMPONENT.txt" <<EOF
component: $name
licence: $licence
elected LGPL version: $elected
revision: $rev
upstream base: ${upstream:-unrecorded}
bundled: $STAMP

Rebuild and substitution instructions:
  spikes/LEGAL-001/lgpl-substitution/README.md
Verify substitution still works:
  spikes/LEGAL-001/lgpl-substitution/prove-substitution.sh
EOF
  printf '   %-10s %s (%s)\n' "$name" "${rev:0:12}" "$elected"
}

say "1. corresponding source for LGPL components"
# "2.1-or-later" gives the distributor a choice of version; recording which was
# elected is itself an obligation, not bookkeeping.
bundle_component wine "$WINESRC" "LGPL-2.1-or-later" "2.1" "$(git -C "$WINESRC" rev-parse --verify -q master 2>/dev/null || echo '')"
bundle_component fex "$FEXSRC" "MIT" "n/a — MIT, no election" "$(git -C "$FEXSRC" rev-parse --verify -q main 2>/dev/null || echo '')"
if [[ -n $DXMTSRC ]]; then
  bundle_component dxmt "$DXMTSRC" "LGPL-2.1-or-later" "2.1" ""
else
  gap "dxmt: source tree not supplied - DXMT is LGPL-2.1-or-later since v0.80 and MUST be bundled before external release"
fi
gap "gstreamer: not linked in this build, so nothing to bundle; a per-plug-in audit is required if it is ever linked"

say "2. licence texts"
mkdir -p "$BUNDLE/licences"
for f in "$WINESRC/COPYING.LIB" "$WINESRC/LICENSE" "$FEXSRC/LICENSE"; do
  [[ -f $f ]] && cp -f "$f" "$BUNDLE/licences/$(basename "$(dirname "$f")")-$(basename "$f")" 2>/dev/null || true
done
n=$(find "$BUNDLE/licences" -type f | wc -l | tr -d ' ')
if [[ $n -gt 0 ]]; then
  printf '   %s licence text(s)\n' "$n"
else
  gap "no licence texts collected"
fi

say "3. SBOM"
if [[ -f $REPO/spikes/LEGAL-001/codec-clean/sbom.json ]]; then
  cp -f "$REPO/spikes/LEGAL-001/codec-clean/sbom.json" "$OUT/sbom.json"
  printf '   sbom.json (%s components)\n' "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["components"]))' "$OUT/sbom.json" 2>/dev/null || echo '?')"
else
  gap "no SBOM found - run spikes/LEGAL-001/codec-clean/generate-sbom.sh (#24)"
fi

say "4. release record"
{
  echo "version: $VERSION"
  echo "built: $STAMP"
  echo "host: $(uname -sm)"
  echo
  echo "Corresponding source is published for every LGPL component listed above,"
  echo "with the elected LGPL version recorded per component. Rebuild and"
  echo "substitution instructions travel with the bundle."
  echo
  if ((${#GAPS[@]})); then
    echo "KNOWN GAPS - this build must not be distributed externally until these close:"
    printf '  - %s\n' "${GAPS[@]}"
  else
    echo "No known gaps."
  fi
} >"$OUT/RELEASE-RECORD.txt"

(cd "$OUT" && find . -type f -exec shasum -a 256 {} \; | sort -k2 >SHA256SUMS)

echo
say "release $VERSION staged in $OUT"
if ((${#GAPS[@]})); then
  echo "   ${#GAPS[@]} gap(s) recorded in RELEASE-RECORD.txt — NOT distributable" >&2
  exit 1
fi
echo "   no gaps"
