#!/usr/bin/env bash
# Alloy pinned-dependency fetcher
# Author: Tim Isaev
# Clones spike upstreams into third_party/src/ (shallow), fetches the llvm-mingw
# release toolchain, and records exact revisions in third_party/deps.lock.
# DXMT is deliberately NOT fetched (deferred; ADR-0012 exclusion guard — see MANIFEST.toml).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/src"
TOOLCHAINS="$ROOT/tools/toolchains"
LOCK="$ROOT/third_party/deps.lock"
LOCKTMP="$(mktemp -d)/deps.lock"
mkdir -p "$SRC" "$TOOLCHAINS"

clone_pin() { # name url
  local name=$1 url=$2 dir="$SRC/$1"
  if [[ -d "$dir/.git" ]]; then
    echo "== $name: already cloned"
  else
    echo "== $name: cloning (shallow) $url"
    git clone --depth 1 --recurse-submodules --shallow-submodules "$url" "$dir"
  fi
  local rev branch
  rev=$(git -C "$dir" rev-parse HEAD)
  branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD)
  echo "$name $rev $branch" >>"$LOCKTMP.entries"
}

fetch_llvm_mingw() {
  local api="https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest"
  local tag asset url
  tag=$(curl -fsSL "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
  asset="llvm-mingw-${tag}-ucrt-macos-universal.tar.xz"
  url="https://github.com/mstorsjo/llvm-mingw/releases/download/${tag}/${asset}"
  if [[ -d "$TOOLCHAINS/llvm-mingw-${tag}-ucrt-macos-universal" ]]; then
    echo "== llvm-mingw ${tag}: already present"
  else
    echo "== llvm-mingw: fetching ${asset}"
    curl -fL --retry 3 -o "$TOOLCHAINS/$asset" "$url"
    tar -xf "$TOOLCHAINS/$asset" -C "$TOOLCHAINS"
    rm "$TOOLCHAINS/$asset"
  fi
  echo "llvm-mingw $tag release-binary" >>"$LOCKTMP.entries"
}

: >"$LOCKTMP.entries"
echo "# Alloy dependency lock — written $(date -u +%Y-%m-%dT%H:%M:%SZ) by fetch-deps.sh" >"$LOCKTMP.header"
clone_pin fex https://github.com/FEX-Emu/FEX.git
clone_pin wine https://gitlab.winehq.org/wine/wine.git
fetch_llvm_mingw
cat "$LOCKTMP.header" "$LOCKTMP.entries" >"$LOCK"
rm -f "$LOCKTMP.header" "$LOCKTMP.entries"
echo ""
echo "== deps.lock:"
cat "$LOCK"
