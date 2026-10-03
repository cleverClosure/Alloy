#!/usr/bin/env bash
# Prove the release bundle is the source that was built, and that gaps are loud.
# Author: Tim Isaev
#
# make-release.sh makes claims a recipient will rely on: this archive is what
# the binary was built from, these are the components, nothing is missing. Each
# claim is checked here against miniature source trees whose right answer is
# known by construction - including a tree in the state that exposed the
# problem: a fork that exists only as uncommitted changes, with an upstream
# directory deleted from it.
#
# Usage: make-release-selftest.sh   (or: make-release.sh --selftest)
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/alloy-release-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail=0
pass() { printf 'ok: %s\n' "$1"; }
fold() {
  printf 'FAIL: %s\n' "$1" >&2
  shift
  printf '%s\n' "$@" | sed 's/^/        /' >&2
  fail=1
}

# ── fixtures ──────────────────────────────────────────────────────────────────

g() { # repo args... - git with nothing inherited from the machine's config
  local repo=$1
  shift
  git -C "$repo" -c user.name=Test -c user.email=test@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# otool is stubbed so linkage is a fixture: a file's dependencies are whatever
# its .links sidecar says.
mkdir -p "$work/bin"
cat >"$work/bin/otool" <<'STUB'
#!/usr/bin/env bash
echo "$2:"
[[ -e $2.links ]] && cat "$2.links"
exit 0
STUB
chmod +x "$work/bin/otool"

make_fixture() { # dir
  local d=$1
  mkdir -p "$d/wine/dlls/ntdll" "$d/fex" "$d/dxmt/src/d3d11" "$d/dxmt/src/d3d12" \
    "$d/build/dlls/ntdll" "$d/build/dlls/libarm64ecfex/aarch64-windows" \
    "$d/dxmt-build/meson-private" "$d/dxmt-build/src/d3d11" "$d/dxmt-build/src/dxgi" \
    "$d/dxmt-build/src/winemetal/unix"

  git init -q -b master "$d/wine"
  echo "LGPL text" >"$d/wine/COPYING.LIB"
  echo "wine authors" >"$d/wine/AUTHORS"
  echo "upstream" >"$d/wine/dlls/ntdll/a.c"
  g "$d/wine" add -A
  g "$d/wine" commit -q -m upstream
  g "$d/wine" switch -q -c alloy
  echo "fork change" >"$d/wine/dlls/ntdll/a.c"
  g "$d/wine" commit -q -am fork

  git init -q -b main "$d/fex"
  echo "MIT text" >"$d/fex/LICENSE"
  g "$d/fex" add -A
  g "$d/fex" commit -q -m upstream

  # The state that exposed the problem: the fork is uncommitted, and a
  # directory of upstream code is deleted from the tree that gets built.
  git init -q -b main "$d/dxmt"
  echo "LGPL text" >"$d/dxmt/COPYING.LIB"
  echo "upstream" >"$d/dxmt/src/d3d11/a.cpp"
  echo "UPSTREAM-CODE-WE-DO-NOT-BUILD" >"$d/dxmt/src/d3d12/unbuilt.cpp"
  g "$d/dxmt" add -A
  g "$d/dxmt" commit -q -m upstream
  rm -r "$d/dxmt/src/d3d12"
  echo "instrumented" >"$d/dxmt/src/d3d11/a.cpp"
  echo "new header" >"$d/dxmt/src/d3d11/new.hpp"

  printf 'junk\n\n  $ /somewhere/else/wine/configure --with-mingw --enable-archs=arm64ec,aarch64\n' \
    >"$d/build/config.log"
  : >"$d/build/dlls/ntdll/ntdll.so"
  : >"$d/build/dlls/libarm64ecfex/aarch64-windows/libarm64ecfex.dll"
  printf '[options]\nenable_d3d12 = false\n' >"$d/dxmt-build/meson-private/cmd_line.txt"
  echo d3d11 >"$d/dxmt-build/src/d3d11/d3d11.dll"
  echo dxgi >"$d/dxmt-build/src/dxgi/dxgi.dll"
  echo winemetal >"$d/dxmt-build/src/winemetal/unix/winemetal.so"
}

# run <fixture> [dxmt|-] : sets $out, $status, $rel
run() {
  local d=$1 dxmt=${2-dxmt}
  rel="$d/out"
  out=$(
    cd "$d" || exit 99
    PATH="$work/bin:$PATH" \
      ALLOY_WINE_BUILD=${WINE_BUILD-"$d/build"} \
      ALLOY_DXMT_BUILD="$d/dxmt-build" \
      ALLOY_SOURCE_URL="https://example.invalid/source" \
      ALLOY_RUNTIME_ROOT="" \
      bash "$here/make-release.sh" 9.9.9-test "$rel" "$d/wine" "$d/fex" \
      ${dxmt:+"$d/$dxmt"} 2>&1
  )
  status=$?
}
gaps() { sed -n 's/^  - //p' "$rel/RELEASE-RECORD.txt"; }

# The carve-out text is a real file with a real status. While it is a draft it
# is a gap on every release, so "no other gap" is the strongest claim available.
draft=0
grep -q '^Status: draft' "$here/LGPL-RIGHTS.md" 2>/dev/null && draft=1
only_expected_gaps() { # -> 0 when the draft carve-out is the only gap, if any
  local others
  others=$(gaps | grep -v 'licence carve-out: LGPL-RIGHTS.md is still a draft' || true)
  [[ -z $others ]]
}

# ── 1. An uncommitted fork is bundled as built, and said to be uncommitted ────
d="$work/f1"
make_fixture "$d"
before=$(g "$d/dxmt" status --porcelain)
objects_before=$(find "$d/dxmt/.git/objects" -type f | wc -l)
run "$d"
mkdir -p "$d/x"
tar -xzf "$rel/corresponding-source/dxmt/dxmt-src.tar.gz" -C "$d/x" 2>/dev/null
patch="$rel/corresponding-source/dxmt/dxmt-fork.patch"
if ((status == 0)); then
  fold "dirty-tree: a release built from uncommitted source reported no gap" "$out"
elif ! gaps | grep -q 'dxmt: built from 3 uncommitted path'; then
  fold "dirty-tree: the uncommitted state is not recorded as a gap" "$(gaps)"
elif [[ $(cat "$d/x/dxmt-src/src/d3d11/a.cpp" 2>/dev/null) != instrumented ]]; then
  fold "dirty-tree: the archive holds the committed file, not the one that was built" \
    "$(cat "$d/x/dxmt-src/src/d3d11/a.cpp" 2>&1)"
elif [[ ! -f $d/x/dxmt-src/src/d3d11/new.hpp ]]; then
  fold "dirty-tree: an untracked source file is missing from the archive" "$(find "$d/x" -type f)"
elif [[ -e $d/x/dxmt-src/src/d3d12 ]]; then
  fold "dirty-tree: a directory deleted from the built tree is in the archive" "$(find "$d/x" -type f)"
else
  pass dirty-tree
fi

# ── 2. The fork patch names a deleted upstream file without reproducing it ────
if ! grep -q 'src/d3d12/unbuilt.cpp' "$patch"; then
  fold "deleted-upstream: the patch does not record the deletion" "$(cat "$patch")"
elif grep -q 'UPSTREAM-CODE-WE-DO-NOT-BUILD' "$patch"; then
  fold "deleted-upstream: the patch reproduces the code that was deleted" "$(cat "$patch")"
elif ! grep -q '+instrumented' "$patch"; then
  fold "deleted-upstream: the patch lost the real modification" "$(cat "$patch")"
else
  pass deleted-upstream
fi

# ── 3. Snapshotting writes nothing into the source checkout ───────────────────
if [[ $(g "$d/dxmt" status --porcelain) != "$before" ]]; then
  fold "source-untouched: the working tree or index changed" "$(g "$d/dxmt" status --porcelain)"
elif (($(find "$d/dxmt/.git/objects" -type f | wc -l) != objects_before)); then
  fold "source-untouched: objects were written into the source repository"
else
  pass source-untouched
fi

# ── 4. A clean tree is exactly its commit, and the rest of the bundle is whole ─
bundle="$rel/corresponding-source"
if ! grep -q "source state: exactly commit $(g "$d/wine" rev-parse HEAD)" "$bundle/wine/COMPONENT.txt"; then
  fold "clean-tree: a clean tree is not recorded as its commit" "$(cat "$bundle/wine/COMPONENT.txt")"
elif ! grep -q '+fork change' "$bundle/wine/wine-fork.patch"; then
  fold "clean-tree: fork patch does not hold the fork's change" "$(cat "$bundle/wine/wine-fork.patch")"
elif ! grep -q -- '--with-mingw --enable-archs=arm64ec,aarch64' "$bundle/BUILD-INPUTS.txt" ||
  ! grep -q -- 'configure --with-mingw --enable-archs=arm64ec,aarch64' "$bundle/REBUILD.md"; then
  fold "clean-tree: configure arguments not carried into the bundle" "$(cat "$bundle/BUILD-INPUTS.txt")"
elif grep -q '/somewhere/else' "$bundle/BUILD-INPUTS.txt"; then
  fold "clean-tree: a build-machine path leaked into the bundle" "$(cat "$bundle/BUILD-INPUTS.txt")"
elif [[ $(grep -c '^## ' "$bundle/NOTICES.md") != 3 ]] || ! grep -q 'example.invalid/source' "$bundle/NOTICES.md"; then
  fold "clean-tree: notices do not list every component and the source location" "$(cat "$bundle/NOTICES.md")"
elif [[ ! -f $bundle/licences/wine/COPYING.LIB || ! -f $bundle/licences/wine/AUTHORS || ! -f $bundle/licences/fex/LICENSE ]]; then
  fold "clean-tree: licence texts missing" "$(find "$bundle/licences" -type f)"
elif [[ $(jq -r '.components[] | select(.name == "wine") | .properties[0].value' "$rel/sbom.json") != 2.1 ]]; then
  fold "clean-tree: SBOM does not record the elected LGPL version" "$(cat "$rel/sbom.json")"
elif [[ $(jq -r '[.components[] | select(.name | startswith("dxmt-")) | .version] | unique | join(",")' "$rel/sbom.json") != "tree $(sed -n 's/^source tree: //p' "$bundle/dxmt/COMPONENT.txt")" ]]; then
  fold "clean-tree: SBOM does not tie DXMT's binaries to the bundled source" "$(jq -c '.components[]' "$rel/sbom.json")"
elif [[ $(jq -r '.components[] | select(.name == "dxmt-d3d11") | .hashes[0].content' "$rel/sbom.json") != "$(shasum -a 256 "$d/dxmt-build/src/d3d11/d3d11.dll" | cut -d' ' -f1)" ]]; then
  fold "clean-tree: SBOM hash is not the hash of the provider that ships" "$(jq -c '.components[]' "$rel/sbom.json")"
elif ! (cd "$rel" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1); then
  fold "clean-tree: SHA256SUMS does not verify"
else
  pass clean-tree
fi

# ── 5. Once committed, the same fork has no gap of its own ────────────────────
g "$d/dxmt" switch -q -c alloy
g "$d/dxmt" add -A
g "$d/dxmt" commit -q -m "alloy fork"
run "$d"
if ! only_expected_gaps; then
  fold "complete: a fully provisioned release still reports a gap" "$(gaps)"
elif ((draft == 0 && status != 0)) || ((draft == 1 && status == 0)); then
  fold "complete: exit status does not match the gap list" "status=$status" "$(gaps)"
else
  pass complete
fi

# ── 6. GStreamer linked: every library is named, and it is a gap ──────────────
mkdir -p "$d/build/dlls/winegstreamer"
: >"$d/build/dlls/winegstreamer/winegstreamer.so"
printf '\t/opt/homebrew/lib/libgstreamer-1.0.0.dylib (compatibility version 1.0.0)\n\t/opt/homebrew/lib/libgstvideo-1.0.0.dylib (compatibility version 1.0.0)\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n' \
  >"$d/build/dlls/winegstreamer/winegstreamer.so.links"
run "$d"
if ! gaps | grep -q 'gstreamer: linked by the runtime.*libgstreamer-1.0.0.dylib libgstvideo-1.0.0.dylib'; then
  fold "gstreamer: linked libraries are not each named in a gap" "$(gaps)"
elif ! grep -q 'winegstreamer.so' "$rel/corresponding-source/AUDIT-gstreamer.txt"; then
  fold "gstreamer: the audit does not say which binary links it" "$(cat "$rel/corresponding-source/AUDIT-gstreamer.txt")"
elif grep -q 'libSystem' "$rel/corresponding-source/AUDIT-gstreamer.txt"; then
  fold "gstreamer: the audit lists a library that is not GStreamer" "$(cat "$rel/corresponding-source/AUDIT-gstreamer.txt")"
else
  pass gstreamer
fi
rm -r "$d/build/dlls/winegstreamer"

# ── 7. MoltenVK present in the runtime is a gap ───────────────────────────────
mkdir -p "$d/build/lib"
: >"$d/build/lib/libMoltenVK.dylib"
run "$d"
if ! gaps | grep -q 'moltenvk: present in the runtime'; then
  fold "moltenvk: shipped but not reported" "$(gaps)"
else
  pass moltenvk
fi
rm -r "$d/build/lib"

# ── 8. A codec library reachable in the runtime: this is not the staged one ───
mkdir -p "$d/build/dlls/winedmo"
: >"$d/build/dlls/winedmo/winedmo.so"
run "$d"
if ! gaps | grep -q 'ffmpeg: reachable in this runtime'; then
  fold "raw-runtime: bundled against a runtime that still carries the codec path" "$(gaps)"
else
  pass raw-runtime
fi
rm -r "$d/build/dlls/winedmo"

# ── 9. DXMT bundled, but a binary is not where the SBOM can hash it ───────────
rm "$d/dxmt-build/src/dxgi/dxgi.dll"
run "$d"
if ! gaps | grep -q "SBOM does not list DXMT's three binaries"; then
  fold "sbom-dxmt: a DXMT binary missing from the SBOM went unreported" "$(gaps)"
else
  pass sbom-dxmt
fi
echo dxgi >"$d/dxmt-build/src/dxgi/dxgi.dll"

# ── 10. DXMT source not supplied ──────────────────────────────────────────────
run "$d" ""
if ((status == 0)) || ! gaps | grep -q 'dxmt: source tree not supplied'; then
  fold "no-dxmt: an LGPL component without source did not stop the release" "$(gaps)"
else
  pass no-dxmt
fi

# ── 11. No runtime to look at: nothing is claimed about it ────────────────────
WINE_BUILD="" run "$d"
if ((status == 0)); then
  fold "no-runtime: reported no gap without a runtime to audit" "$out"
elif ! gaps | grep -q 'gstreamer: not audited' || ! gaps | grep -q 'SBOM not generated' ||
  ! gaps | grep -q 'wine: configure arguments not recorded'; then
  fold "no-runtime: an unaudited runtime was not reported as such" "$(gaps)"
elif [[ -e $rel/sbom.json ]]; then
  fold "no-runtime: published an SBOM for a runtime it never saw"
else
  pass no-runtime
fi

echo
if ((fail == 0)); then
  echo "MAKE-RELEASE-SELFTEST: pass — the bundle is the source that was built, and every gap is recorded"
else
  echo "MAKE-RELEASE-SELFTEST: FAIL — the release bundle does not prove what it claims." >&2
fi
exit $fail
