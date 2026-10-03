#!/usr/bin/env bash
# dxmt-install.sh — wire and verify the Wine dylibs a DXMT install depends on
# Author: Tim Isaev
#
# DXMT's winemetal.so is not self-contained. It links @rpath/{ntdll,winemac}.so,
# and winemac needs win32u.so, because DXMT expects to be installed into a Wine
# aarch64-unix directory where those are its siblings. An install kept outside
# the Wine tree therefore carries three symlinks beside winemetal.so that point
# at the Wine build's own dylibs (GFX-001 result 03, section 3).
#
# Those links were first made by hand as absolute paths, and the repository was
# then renamed. All three dangled, winemetal.so could no longer load, and D3D11
# fell back to Wine's builtin d3d11 with "device creation failed: 80004005" -
# which reads as a DXMT or Metal regression rather than a missing file (#35).
#
# So the links are built here, relative, from a repo root computed from this
# script's own location, and `check` refuses loudly when an install is not
# bound to the Wine build a run is about to use.
#
# Usage:
#   dxmt-install.sh wire  [install-dir] [wine-build]   (re)create the links, then check
#   dxmt-install.sh check [install-dir] [wine-build]   exit 1 unless bound to wine-build
#   dxmt-install.sh selftest
#
# Defaults: install-dir is spikes/GFX-001/work/dxmt-install, and wine-build is
# $ALLOY_WINE_BUILD, or spikes/WINE-001/work/build-2 when that is unset.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../../.." && pwd -P)

# link name : the dylib's path inside a Wine build tree
readonly SIBLINGS=(
  "ntdll:dlls/ntdll/ntdll.so"
  "winemac:dlls/winemac.drv/winemac.so"
  "win32u:dlls/win32u/win32u.so"
)

usage() {
  sed -n '20,26p' "$0" | sed 's/^# \{0,1\}//'
}

relative_to() { # target dir -> target as a path relative to dir
  python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"
}

check_install() { # install-dir wine-build -> 0 when bound, 1 otherwise
  local install=$1 build=$2 unix_dir entry name link expected
  local problems=()
  unix_dir="$install/aarch64-unix"

  if [[ ! -f $unix_dir/winemetal.so ]]; then
    problems+=("no winemetal.so in $unix_dir")
  fi
  for entry in "${SIBLINGS[@]}"; do
    name=${entry%%:*}
    link="$unix_dir/$name.so"
    expected="$build/${entry#*:}"
    if [[ ! -f $expected ]]; then
      problems+=("the Wine build has no ${entry#*:}: $build")
    elif [[ ! -L $link && ! -e $link ]]; then
      problems+=("$name.so is missing")
    elif [[ ! -e $link ]]; then
      problems+=("$name.so dangles -> $(readlink "$link")")
    elif [[ ! $link -ef $expected ]]; then
      # Same name, different file: dyld would load a second copy of a Wine
      # dylib instead of binding to the one the process already has.
      if [[ -L $link ]]; then
        problems+=("$name.so points outside this Wine build -> $(readlink "$link")")
      else
        problems+=("$name.so is a copy, not a link to this Wine build's file")
      fi
    fi
  done

  if ((${#problems[@]} == 0)); then
    printf 'dxmt-install: %s is bound to %s\n' "$install" "$build"
    return 0
  fi
  {
    printf 'dxmt-install: %s is NOT usable:\n' "$install"
    printf '  - %s\n' "${problems[@]}"
    printf 'winemetal.so cannot load like this, and D3D11 then falls back to\n'
    printf "Wine's builtin d3d11: a provider test silently becomes a builtin test.\n"
    printf 'fix: %s wire %q %q\n' "$0" "$install" "$build"
  } >&2
  return 1
}

wire_install() { # install-dir wine-build
  local install=$1 build=$2 unix_dir entry target
  unix_dir="$install/aarch64-unix"

  if [[ ! -d $unix_dir ]]; then
    echo "dxmt-install: no such install directory: $unix_dir" >&2
    return 1
  fi
  # Every target is confirmed before any link is touched, so a wrong wine-build
  # argument cannot leave an install half rewired.
  for entry in "${SIBLINGS[@]}"; do
    if [[ ! -f $build/${entry#*:} ]]; then
      echo "dxmt-install: the Wine build has no ${entry#*:}: $build" >&2
      return 1
    fi
  done

  # Physical paths: a relative link is resolved from where the directory really
  # is, not from a symlinked route to it.
  unix_dir=$(cd "$unix_dir" && pwd -P)
  build=$(cd "$build" && pwd -P)
  for entry in "${SIBLINGS[@]}"; do
    target=$(relative_to "$build/${entry#*:}" "$unix_dir")
    ln -sfn "$target" "$unix_dir/${entry%%:*}.so"
  done
  check_install "$install" "$build"
}

# ── self-test ─────────────────────────────────────────────────────────────────

run_selftest() {
  local work fail=0 out status tree build unix_dir
  work=$(mktemp -d "${TMPDIR:-/tmp}/alloy-dxmt-install.XXXXXX")
  # shellcheck disable=SC2064 # expand now: $work is local to this function
  trap "rm -rf '$work'" EXIT

  pass() { printf 'ok: %s\n' "$1"; }
  fold() {
    printf 'FAIL: %s\n' "$1" >&2
    shift
    printf '%s\n' "$@" | sed 's/^/        /' >&2
    fail=1
  }

  # A miniature repository holding a copy of this script, so the defaults are
  # computed from the copy's own location exactly as they are in the real tree.
  make_tree() { # root
    local root=$1 entry
    mkdir -p "$root/spikes/GFX-001/harness" \
      "$root/spikes/GFX-001/work/dxmt-install/aarch64-unix"
    cp "$0" "$root/spikes/GFX-001/harness/dxmt-install.sh"
    : >"$root/spikes/GFX-001/work/dxmt-install/aarch64-unix/winemetal.so"
    make_build "$root/spikes/WINE-001/work/build-2"
  }
  make_build() { # wine-build
    local entry
    for entry in "${SIBLINGS[@]}"; do
      mkdir -p "$(dirname "$1/${entry#*:}")"
      : >"$1/${entry#*:}"
    done
  }
  run() { # root args... -> $out, $status
    local root=$1
    shift
    if out=$(env -u ALLOY_WINE_BUILD \
      bash "$root/spikes/GFX-001/harness/dxmt-install.sh" "$@" 2>&1); then
      status=0
    else
      status=$?
    fi
  }

  # 1. Never wired: refused, naming what is missing.
  tree="$work/t1/Alloy"
  make_tree "$tree"
  run "$tree" check
  if ((status == 0)); then
    fold "unwired: accepted an install with no links" "$out"
  elif [[ $out != *'ntdll.so is missing'* || $out != *'fix: '* ]]; then
    fold "unwired: did not name the missing link and the fix" "$out"
  else
    pass unwired
  fi

  # 2. Wired from the computed root: accepted, and the links are relative.
  unix_dir="$tree/spikes/GFX-001/work/dxmt-install/aarch64-unix"
  run "$tree" wire
  if ((status != 0)); then
    fold "wire: failed on a well-formed tree" "$out"
  elif [[ $(readlink "$unix_dir/winemac.so") == /* ]]; then
    fold "wire: made an absolute link" "$(readlink "$unix_dir/winemac.so")"
  else
    pass wire
  fi

  # 3. The repository is renamed - what actually broke the install in #35.
  mv "$work/t1/Alloy" "$work/t1/Renamed"
  tree="$work/t1/Renamed"
  run "$tree" check
  if ((status != 0)); then
    fold "renamed: the links did not survive renaming the repository" "$out"
  else
    pass renamed
  fi

  # 4. The original defect: absolute links into a tree that is gone.
  tree="$work/t4/Alloy"
  make_tree "$tree"
  unix_dir="$tree/spikes/GFX-001/work/dxmt-install/aarch64-unix"
  ln -s "$work/gone/dlls/ntdll/ntdll.so" "$unix_dir/ntdll.so"
  ln -s "$work/gone/dlls/winemac.drv/winemac.so" "$unix_dir/winemac.so"
  ln -s "$work/gone/dlls/win32u/win32u.so" "$unix_dir/win32u.so"
  run "$tree" check
  if ((status == 0)); then
    fold "dangling: accepted an install whose links dangle" "$out"
  elif [[ $out != *'winemac.so dangles'* || $out != *'builtin'* ]]; then
    fold "dangling: did not say which link dangles and what it costs" "$out"
  else
    pass dangling
  fi

  # 5. wire repairs exactly that state.
  run "$tree" wire
  if ((status != 0)); then
    fold "repair: wire did not repair dangling links" "$out"
  else
    pass repair
  fi

  # 6. Links that resolve, but into another Wine build: a second copy of ntdll.
  build="$work/other-build"
  make_build "$build"
  ln -sfn "$build/dlls/ntdll/ntdll.so" "$unix_dir/ntdll.so"
  run "$tree" check
  if ((status == 0)); then
    fold "other-build: accepted a link into a different Wine build" "$out"
  elif [[ $out != *'ntdll.so points outside this Wine build'* ]]; then
    fold "other-build: wrong failure" "$out"
  else
    pass other-build
  fi

  # 7. The same install is correct when that other build is the one named.
  run "$tree" wire "$tree/spikes/GFX-001/work/dxmt-install" "$build"
  if ((status != 0)); then
    fold "explicit-build: failed to wire against a named Wine build" "$out"
  else
    run "$tree" check
    if ((status == 0)); then
      fold "explicit-build: default build accepted links into the named one" "$out"
    else
      pass explicit-build
    fi
  fi

  # 8. A Wine build missing one dylib changes nothing - not even the links whose
  # targets do exist, which would leave the install bound to two builds at once.
  make_build "$work/partial-build"
  rm "$work/partial-build/dlls/win32u/win32u.so"
  run "$tree" wire "$tree/spikes/GFX-001/work/dxmt-install" "$work/partial-build"
  if ((status == 0)); then
    fold "bad-build: wired against an incomplete Wine build" "$out"
  elif [[ ! $unix_dir/ntdll.so -ef $build/dlls/ntdll/ntdll.so ]]; then
    fold "bad-build: a failed wire still rewrote the links" "$(readlink "$unix_dir/ntdll.so")"
  else
    pass bad-build
  fi

  # 9. No winemetal.so at all.
  tree="$work/t9/Alloy"
  make_tree "$tree"
  run "$tree" wire
  rm "$tree/spikes/GFX-001/work/dxmt-install/aarch64-unix/winemetal.so"
  run "$tree" check
  if ((status == 0)); then
    fold "no-winemetal: accepted an install with no winemetal.so" "$out"
  else
    pass no-winemetal
  fi

  echo
  if ((fail == 0)); then
    echo "DXMT-INSTALL-SELFTEST: pass — a stale install is refused, and wiring survives a rename"
  else
    echo "DXMT-INSTALL-SELFTEST: FAIL — a stale DXMT install can still pass unnoticed." >&2
  fi
  return "$fail"
}

# ── entry point ───────────────────────────────────────────────────────────────

main() {
  local cmd=${1:-}
  local install=${2:-"$REPO/spikes/GFX-001/work/dxmt-install"}
  local build=${3:-${ALLOY_WINE_BUILD:-"$REPO/spikes/WINE-001/work/build-2"}}

  case $cmd in
    wire) wire_install "$install" "$build" ;;
    check) check_install "$install" "$build" ;;
    selftest) run_selftest ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
