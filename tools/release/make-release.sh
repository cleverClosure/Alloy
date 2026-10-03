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
# The bundle is a snapshot of each source tree as it stands, not of its last
# commit. A tree with uncommitted changes is what the binary was built from, so
# archiving HEAD would publish source that does not correspond to what ships -
# and in the lab that was the normal case, not the exception: DXMT's entire fork
# was uncommitted. A dirty tree is still recorded as a gap, because a release
# that cannot be rebuilt from a commit is not reproducible.
#
# Runs on macOS/Apple silicon against the lab Wine build tree. A hosted GitHub
# runner cannot do this (see spikes/LEGAL-001/lgpl-substitution/README.md).
#
# Usage: make-release.sh <version> <out-dir> <wine-src> <fex-src> [dxmt-src]
#        make-release.sh --selftest
#
# Environment (each one that is missing becomes a recorded gap, not a guess):
#   ALLOY_WINE_BUILD    configured Wine build tree: its configure arguments
#   ALLOY_RUNTIME_ROOT  the runtime that ships, for the linkage audit and the
#                       SBOM; defaults to ALLOY_WINE_BUILD
#   ALLOY_DXMT_BUILD    DXMT meson build directory: its recorded options
#   ALLOY_SOURCE_URL    where this release's bundle is published, for NOTICES
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

say() { printf '== %s\n' "$*"; }
GAPS=()
gap() {
  printf '   GAP: %s\n' "$*"
  GAPS+=("$*")
}

# ── source snapshots ──────────────────────────────────────────────────────────

# Uncommitted content is hashed into a scratch object directory layered over the
# source repository, so snapshotting a dirty tree writes nothing into a checkout
# that other work is using.
overlay_git() { # src args...
  local src=$1 common
  shift
  common=$(cd "$src" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  GIT_OBJECT_DIRECTORY="$SCRATCH/objects" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$common/objects" \
    git -C "$src" "$@"
}

snapshot_tree() { # src -> id of a tree holding the working tree as it stands
  local src=$1 index="$SCRATCH/index.$RANDOM"
  GIT_INDEX_FILE=$index overlay_git "$src" read-tree HEAD
  GIT_INDEX_FILE=$index overlay_git "$src" add -A
  GIT_INDEX_FILE=$index overlay_git "$src" write-tree
  rm -f "$index"
}

# name|licence|elected|upstream-url|base|revision|tree|state|changes
NOTICE_ROWS=()

bundle_component() { # name src-dir licence elected-version upstream-ref
  local name=$1 src=$2 licence=$3 elected=$4 upstream=${5:-}
  local d="$BUNDLE/$name" rev tree changes state base="" url summary="unknown" count=0 f

  if [[ ! -e $src/.git ]]; then
    gap "$name: no source tree at $src - corresponding source NOT bundled"
    return
  fi
  mkdir -p "$d" "$BUNDLE/licences/$name"

  rev=$(git -C "$src" rev-parse HEAD)
  changes=$(git -C "$src" status --porcelain)
  if [[ -z $changes ]]; then
    tree=$(git -C "$src" rev-parse 'HEAD^{tree}')
    state="exactly commit $rev"
  else
    count=$(wc -l <<<"$changes" | tr -d ' ')
    tree=$(snapshot_tree "$src")
    state="commit $rev plus $count uncommitted path(s)"
    gap "$name: built from $count uncommitted path(s) - bundled as a snapshot of the working tree; commit them before external release"
  fi

  overlay_git "$src" archive --format=tar --prefix="$name-src/" \
    --mtime="$(git -C "$src" log -1 --format=%cI)" "$tree" |
    gzip -n >"$d/$name-src.tar.gz"

  if [[ -n $upstream ]] && base=$(git -C "$src" merge-base HEAD "$upstream" 2>/dev/null); then
    # -D: a file the fork deletes is named, not reproduced. The whole tree is in
    # the archive; this patch answers "what did we change", and upstream code we
    # chose not to build is not part of that answer.
    overlay_git "$src" diff -D "$base" "$tree" >"$d/$name-fork.patch"
    summary=$(overlay_git "$src" diff --shortstat "$base" "$tree" | sed 's/^ *//')
    summary="${summary:-no changes}; $(git -C "$src" rev-list --count "$base"..HEAD) commit(s)"
    printf '%s\n' "$base" >"$d/UPSTREAM-BASE"
  else
    gap "$name: no upstream base recorded - the fork diff cannot be produced"
  fi
  url=$(git -C "$src" remote get-url origin 2>/dev/null || echo unrecorded)

  for f in "$src"/COPYING* "$src"/LICENSE* "$src"/AUTHORS; do
    [[ -f $f ]] && cp -f "$f" "$BUNDLE/licences/$name/"
  done
  if [[ -z $(ls -A "$BUNDLE/licences/$name") ]]; then
    gap "$name: no licence text found in the source tree"
  fi

  {
    cat <<EOF
component: $name
licence: $licence
elected LGPL version: $elected
upstream: $url
upstream base: ${base:-unrecorded}
revision: $rev
source tree: $tree
source state: $state
changes since upstream base: $summary
bundled: $STAMP

Rebuild and substitution instructions: ../REBUILD.md
Licence texts: ../licences/$name/
EOF
    if [[ -n $changes ]]; then
      printf '\nUncommitted paths included in this snapshot (git status):\n%s\n' "$changes"
    fi
  } >"$d/COMPONENT.txt"

  NOTICE_ROWS+=("$name|$licence|$elected|$url|${base:-unrecorded}|$rev|$tree|$state|$summary")
  printf '   %-6s %s  %s\n' "$name" "${tree:0:12}" "$state"
}

# ── build inputs ──────────────────────────────────────────────────────────────

toolchain_id() {
  local cc
  if cc=$(command -v x86_64-w64-mingw32-clang); then
    printf '%s (%s)' "$(basename "$(cd "$(dirname "$cc")/.." && pwd -P)")" \
      "$("$cc" --version 2>/dev/null | head -1)"
  else
    printf 'llvm-mingw not on PATH when the bundle was made'
  fi
}

record_build_inputs() {
  local f="$BUNDLE/BUILD-INPUTS.txt" args
  {
    echo "Build inputs for release $VERSION, recorded $STAMP"
    echo
    echo "host: $(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r) ($(uname -m))"
    echo "host compiler: $(clang --version 2>/dev/null | head -1 || echo unavailable)"
    echo "cross toolchain: $(toolchain_id)"
    echo "meson: $(meson --version 2>/dev/null || echo unavailable)"
    echo "ninja: $(ninja --version 2>/dev/null || echo unavailable)"
    # Wine's configure refuses the bison 2.3 that macOS ships; the one found
    # first on PATH is the one a rebuild needs.
    echo "bison: $(bison --version 2>/dev/null | head -1 || echo unavailable)"
    echo "flex: $(flex --version 2>/dev/null | head -1 || echo unavailable)"
    echo
  } >"$f"

  if [[ -n $WINE_BUILD && -f $WINE_BUILD/config.log ]]; then
    # config.log records the invocation as "  $ /path/to/configure <arguments>".
    args=$(sed -n 's/^  \$ [^ ]*configure//p' "$WINE_BUILD/config.log" | head -1)
    WINE_CONFIGURE_ARGS=${args# }
    printf 'wine configure arguments:\n  %s\n\n' "${WINE_CONFIGURE_ARGS:-(none)}" >>"$f"
  else
    gap "wine: configure arguments not recorded - set ALLOY_WINE_BUILD to the configured build tree"
  fi

  [[ -d $BUNDLE/dxmt ]] || return 0
  if [[ -n $DXMT_BUILD && -f $DXMT_BUILD/meson-private/cmd_line.txt ]]; then
    {
      echo "dxmt meson options (paths under the repository shown as <repo>):"
      sed "s#$REPO#<repo>#g; s/^/  /" "$DXMT_BUILD/meson-private/cmd_line.txt"
      echo
    } >>"$f"
    if [[ -f $REPO/spikes/GFX-001/cross-arm64ec-darwin-teb.txt ]]; then
      cp -f "$REPO/spikes/GFX-001/cross-arm64ec-darwin-teb.txt" "$BUNDLE/dxmt/"
    fi
  else
    gap "dxmt: meson options not recorded - set ALLOY_DXMT_BUILD to the meson build directory"
  fi
}

write_rebuild_instructions() {
  cat >"$BUNDLE/REBUILD.md" <<EOF
# Rebuilding and substituting the LGPL components

Release $VERSION. These instructions travel with the source they describe, so
they do not depend on access to any repository.

You may modify any LGPL component in this bundle and run the result with the
product. The official runtime stays as shipped; yours is your own build,
unsigned or ad-hoc signed, and it is not refused for being different.

Everything needed is in this directory: each component's source as it was
built (\`<name>/<name>-src.tar.gz\`), what the fork changes against its
upstream (\`<name>/<name>-fork.patch\`), and the build inputs
(\`BUILD-INPUTS.txt\`).

## Wine (LGPL-2.1-or-later; version 2.1 elected)

\`\`\`sh
tar -xzf wine/wine-src.tar.gz
mkdir wine-build && cd wine-build
../wine-src/configure ${WINE_CONFIGURE_ARGS:-<arguments: see BUILD-INPUTS.txt>}
make dlls/ntdll/ntdll.so          # or the library you changed
codesign --force --sign - dlls/ntdll/ntdll.so
\`\`\`

Copy the library over the one at the same relative path in the runtime and
launch as usual. Two things must be on \`PATH\` first, both named with their
versions in \`BUILD-INPUTS.txt\`: the cross toolchain, and bison 3 or newer
(macOS ships 2.3, which Wine's configure refuses).

## DXMT (LGPL-2.1-or-later; version 2.1 elected)

\`\`\`sh
tar -xzf dxmt/dxmt-src.tar.gz
meson setup dxmt-build dxmt-src --cross-file dxmt/cross-arm64ec-darwin-teb.txt \\
  <options: see BUILD-INPUTS.txt>
meson compile -C dxmt-build
codesign --force --sign - dxmt-build/src/winemetal/unix/winemetal.so
\`\`\`

Replace \`d3d11.dll\`, \`dxgi.dll\`, \`winemetal.dll\` or \`winemetal.so\` in the
runtime's DXMT directory with your build.

## Checking that your library is the one that ran

\`tools/prove-bundle.sh\` in this bundle does all of the above for Wine's
\`ntdll.so\`, starting from this directory alone: it unpacks the source,
configures it as recorded, inserts a marker, builds, signs, substitutes into
a copy of the runtime and launches a guest. It fails unless the marker is
absent from the runtime as shipped and present once your library is in place.

    tools/prove-bundle.sh <this release> <runtime>

The same script is a release gate for the official build, so the path above
is tested against every release, not merely described.
EOF
  mkdir -p "$BUNDLE/tools"
  cp -f "$REPO/spikes/LEGAL-001/lgpl-substitution/prove-bundle.sh" \
    "$REPO/spikes/LEGAL-001/lgpl-substitution/prove-substitution.sh" "$BUNDLE/tools/"
}

# ── audits of what ships ──────────────────────────────────────────────────────

# One pass over every binary in the runtime, recorded as "binary<TAB>dependency".
# The audits below read this rather than each running otool again.
scan_linkage() {
  local f
  LINKAGE="$SCRATCH/linkage.tsv"
  : >"$LINKAGE"
  SCANNED=0
  while IFS= read -r f; do
    SCANNED=$((SCANNED + 1))
    otool -L "$f" 2>/dev/null | tail -n +2 | awk -v f="${f#"$RUNTIME"/}" '{ print f "\t" $1 }' >>"$LINKAGE"
  done < <(find "$RUNTIME" \( -name '*.so' -o -name '*.dylib' \) -not -path '*/tests/*' 2>/dev/null)
}

audit_runtime() {
  local hits libs present
  if [[ -z $RUNTIME || ! -d $RUNTIME ]]; then
    gap "gstreamer: not audited - set ALLOY_RUNTIME_ROOT or ALLOY_WINE_BUILD to the runtime that ships"
    gap "moltenvk: not audited - set ALLOY_RUNTIME_ROOT or ALLOY_WINE_BUILD to the runtime that ships"
    return
  fi
  scan_linkage

  # GStreamer is audited per library actually linked, because its core licence
  # says nothing about any one plug-in. No linkage is a complete audit; any
  # linkage is a gap until each library named has its own licence entry.
  hits=$(awk -F'\t' 'tolower($2) ~ /libgst|gstreamer/' "$LINKAGE")
  {
    echo "GStreamer audit for release $VERSION, $STAMP"
    echo "runtime: $RUNTIME"
    echo "binaries scanned: $SCANNED"
    echo
    if [[ -z $hits ]]; then
      echo "No shipped binary links a GStreamer library or plug-in."
      echo "Nothing to audit per plug-in; this must be re-run for every release."
    else
      echo "Linked GStreamer libraries, by binary:"
      printf '%s\n' "$hits" | sed 's/^/  /'
    fi
  } >"$BUNDLE/AUDIT-gstreamer.txt"
  if [[ -n $hits ]]; then
    libs=$(cut -f2 <<<"$hits" | sed 's#.*/##' | sort -u | paste -sd' ' -)
    gap "gstreamer: linked by the runtime - each of these needs its own licence entry before external release: $libs"
  else
    printf '   gstreamer: none linked (%s binaries scanned)\n' "$SCANNED"
  fi

  hits=$(awk -F'\t' 'tolower($2) ~ /moltenvk/' "$LINKAGE")
  present=$(find "$RUNTIME" -iname '*moltenvk*' 2>/dev/null | head -5)
  if [[ -n $hits || -n $present ]]; then
    gap "moltenvk: present in the runtime - Apache-2.0 notice and licence text must ship with it"
  else
    printf '   moltenvk: absent (%s binaries scanned)\n' "$SCANNED"
  fi
}

# ── notices, SBOM, record ─────────────────────────────────────────────────────

write_notices() {
  local row name licence elected url base rev tree state changes
  {
    echo "# Third-party notices"
    echo
    echo "Release $VERSION, $STAMP."
    echo
    if [[ -n $SOURCE_URL ]]; then
      echo "Source for every component below is published with this release at:"
      echo "<$SOURCE_URL>"
    else
      echo "Source for every component below is in this bundle. No public location"
      echo "has been assigned to it yet."
    fi
    echo
    echo "Licence texts and the copyright holders' own notices are under \`licences/\`."
    echo "Where a licence offers \"version 2.1 or later\", version 2.1 is elected."
    echo
    for row in ${NOTICE_ROWS[@]+"${NOTICE_ROWS[@]}"}; do
      IFS='|' read -r name licence elected url base rev tree state changes <<<"$row"
      echo "## $name"
      echo
      echo "- Licence: $licence (elected: $elected)"
      echo "- Upstream: <$url>, from commit \`$base\`"
      echo "- This build: $state (tree \`$tree\`)"
      echo "- Modifications: $changes — in full in \`$name/$name-fork.patch\`"
      echo "- Source: \`$name/$name-src.tar.gz\`"
      echo "- Notices: \`licences/$name/\`"
      echo
    done
  } >"$BUNDLE/NOTICES.md"

  if [[ -z $SOURCE_URL ]]; then
    gap "notices: no durable public location for the source bundle - set ALLOY_SOURCE_URL once a release channel exists"
  fi
  if [[ -f $HERE/LGPL-RIGHTS.md ]]; then
    cp -f "$HERE/LGPL-RIGHTS.md" "$BUNDLE/LGPL-RIGHTS.md"
    if grep -q '^Status: draft' "$BUNDLE/LGPL-RIGHTS.md"; then
      gap "licence carve-out: LGPL-RIGHTS.md is still a draft awaiting counsel"
    fi
  else
    gap "licence carve-out: tools/release/LGPL-RIGHTS.md is missing"
  fi
}

write_sbom() {
  local fexdll wine_rev providers="" unixlib="" dll so dxmt_version=""
  if [[ -z $RUNTIME || ! -d $RUNTIME ]]; then
    gap "SBOM not generated for this build - set ALLOY_RUNTIME_ROOT or ALLOY_WINE_BUILD"
    return
  fi

  # DXMT's binaries sit in separate directories of its build tree; the SBOM
  # generator wants the two provider DLLs side by side.
  if [[ -n $DXMT_BUILD ]]; then
    mkdir -p "$SCRATCH/providers"
    for dll in d3d11 dxgi; do
      [[ -f $DXMT_BUILD/src/$dll/$dll.dll ]] && ln -sf "$DXMT_BUILD/src/$dll/$dll.dll" "$SCRATCH/providers/"
    done
    [[ -n $(ls -A "$SCRATCH/providers") ]] && providers="$SCRATCH/providers"
    so=$(find "$DXMT_BUILD/src/winemetal" -name winemetal.so 2>/dev/null | head -1)
    [[ -n $so ]] && unixlib=$(dirname "$so")
  fi

  # Generated for this build. A checked-in SBOM describes whichever build it
  # was made from, and the one this used to copy was three Wine commits stale.
  fexdll="$RUNTIME/dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
  "$REPO/spikes/LEGAL-001/codec-clean/generate-sbom.sh" "$RUNTIME" "$WINESRC" "$FEXSRC" \
    "$fexdll" "$providers" "$unixlib" >"$SCRATCH/sbom.json"
  if [[ -f $BUNDLE/dxmt/COMPONENT.txt ]]; then
    dxmt_version=$(sed -n 's/^source tree: //p' "$BUNDLE/dxmt/COMPONENT.txt")
  fi

  # The elected LGPL version and what each licence obliges us to ship belong in
  # the same document as the component list, so one file answers "what is in
  # this build and on what terms".
  if ! jq --arg dxmt "$dxmt_version" '
      .components |= map(
        (if (.name | startswith("dxmt-")) and $dxmt != "" then .version = "tree " + $dxmt else . end)
        | if (.licenses[0].license.id == "LGPL-2.1-or-later") and (.version != "absent") then
          . + {properties: [
            {name: "alloy:elected-lgpl-version", value: "2.1"},
            {name: "alloy:obligation", value: "corresponding source, relinkable shared library, notices: see corresponding-source/"}]}
        elif .licenses[0].license.id == "MIT" then
          . + {properties: [
            {name: "alloy:obligation", value: "copyright notice and licence text: corresponding-source/licences/"}]}
        else . end)' "$SCRATCH/sbom.json" >"$OUT/sbom.json"; then
    gap "SBOM could not be generated - generate-sbom.sh did not emit valid JSON"
    return
  fi
  wine_rev=$(git -C "$WINESRC" rev-parse HEAD 2>/dev/null || echo unknown)
  if [[ $(jq -r '.components[] | select(.name == "wine") | .version' "$OUT/sbom.json") != "$wine_rev" ]]; then
    gap "SBOM does not describe the bundled Wine revision"
  fi
  if [[ -d $BUNDLE/dxmt ]] &&
    ! jq -e '[.components[] | select(.name | startswith("dxmt-")) | .hashes[0].content]
             | length == 3 and all(. != "absent")' "$OUT/sbom.json" >/dev/null; then
    gap "SBOM does not list DXMT's three binaries - set ALLOY_DXMT_BUILD to the build that ships"
  fi
  # The generator reports what it finds. A codec library reachable in the
  # runtime means this is the raw build, not the staged one that may ship.
  if jq -e '.components[] | select(.name == "ffmpeg" and .version != "absent")' "$OUT/sbom.json" >/dev/null; then
    gap "ffmpeg: reachable in this runtime - bundle against the staged runtime (stage-runtime.sh), not the raw build"
  fi
  printf '   sbom.json (%s components)\n' "$(jq '.components | length' "$OUT/sbom.json")"
}

# ── the release ───────────────────────────────────────────────────────────────

make_release() {
  VERSION=${1:?version required, e.g. 0.1.0-lab}
  OUT=${2:?output directory required}
  WINESRC=${3:?wine source tree required}
  FEXSRC=${4:?fex source tree required}
  DXMTSRC=${5:-}

  WINE_BUILD=${ALLOY_WINE_BUILD:-}
  RUNTIME=${ALLOY_RUNTIME_ROOT:-$WINE_BUILD}
  DXMT_BUILD=${ALLOY_DXMT_BUILD:-}
  SOURCE_URL=${ALLOY_SOURCE_URL:-}
  WINE_CONFIGURE_ARGS=""
  STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  BUNDLE="$OUT/corresponding-source"

  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/alloy-release.XXXXXX")
  # shellcheck disable=SC2064 # expand now: SCRATCH must not be re-read at exit
  trap "rm -rf '$SCRATCH'" EXIT
  mkdir -p "$SCRATCH/objects"

  rm -rf "$OUT"
  mkdir -p "$BUNDLE"

  say "1. corresponding source, as built"
  # "2.1-or-later" gives the distributor a choice of version; recording which
  # was elected is itself an obligation, not bookkeeping.
  bundle_component wine "$WINESRC" "LGPL-2.1-or-later" "2.1" master
  bundle_component fex "$FEXSRC" "MIT" "n/a (MIT has no version election)" main
  if [[ -n $DXMTSRC ]]; then
    bundle_component dxmt "$DXMTSRC" "LGPL-2.1-or-later" "2.1" main
  else
    gap "dxmt: source tree not supplied - DXMT is LGPL-2.1-or-later since v0.80 and MUST be bundled before external release"
  fi

  say "2. build inputs and rebuild instructions"
  record_build_inputs
  write_rebuild_instructions

  say "3. what the runtime links"
  audit_runtime

  say "4. notices and licence terms"
  write_notices

  say "5. SBOM"
  write_sbom

  say "6. release record"
  {
    echo "version: $VERSION"
    echo "built: $STAMP"
    echo "host: $(uname -sm)"
    echo
    echo "Corresponding source is bundled for every component listed in"
    echo "corresponding-source/NOTICES.md, as a snapshot of the tree it was built"
    echo "from, with the elected LGPL version recorded per component. Rebuild and"
    echo "substitution instructions travel with the bundle."
    echo
    if ((${#GAPS[@]})); then
      echo "KNOWN GAPS - this build must not be distributed externally until these close:"
      printf '  - %s\n' "${GAPS[@]}"
    else
      echo "No known gaps."
    fi
  } >"$OUT/RELEASE-RECORD.txt"

  # Written outside $OUT first, so the list never includes a hash of itself.
  (cd "$OUT" && find . -type f -exec shasum -a 256 {} \; | sort -k2 >"$SCRATCH/SHA256SUMS")
  mv "$SCRATCH/SHA256SUMS" "$OUT/SHA256SUMS"

  echo
  say "release $VERSION staged in $OUT"
  if ((${#GAPS[@]})); then
    echo "   ${#GAPS[@]} gap(s) recorded in RELEASE-RECORD.txt — NOT distributable" >&2
    return 1
  fi
  echo "   no gaps"
}

if [[ ${1:-} == --selftest ]]; then
  exec bash "$HERE/make-release-selftest.sh"
fi
make_release "$@"
