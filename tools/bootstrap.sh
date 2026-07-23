#!/bin/zsh
# MGCR host build-environment bootstrap (Apple Silicon macOS)
# Author: Tim Isaev
# Verifies/installs the host toolchain for Phase-0 spikes. Idempotent.
set -euo pipefail

echo "== MGCR bootstrap =="

if ! xcode-select -p >/dev/null 2>&1; then
  echo "ERROR: Xcode command-line tools missing. Run: xcode-select --install" >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew missing (https://brew.sh)" >&2
  exit 1
fi

# bison: Apple ships 2.3; Wine needs >= 3.0 (brew's is keg-only, prepend to PATH)
BREW_DEPS=(bison meson ccache freetype gnutls)
MISSING=()
for dep in $BREW_DEPS; do
  brew list "$dep" >/dev/null 2>&1 || MISSING+=("$dep")
done
if (( ${#MISSING[@]} )); then
  echo "Installing: ${MISSING[*]}"
  brew install "${MISSING[@]}"
else
  echo "Homebrew deps present: ${BREW_DEPS[*]}"
fi

BISON_PATH="$(brew --prefix bison)/bin"
echo ""
echo "NOTE: brew bison is keg-only. For Wine builds export:"
echo "  export PATH=\"$BISON_PATH:\$PATH\""
"$BISON_PATH/bison" --version | head -1

echo ""
echo "Toolchain summary:"
clang --version | head -1
cmake --version | head -1
ninja --version
echo "bootstrap OK"
