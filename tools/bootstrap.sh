#!/usr/bin/env bash
# Alloy host build-environment bootstrap (Apple Silicon macOS)
# Author: Tim Isaev
# Verifies/installs the host toolchain for Phase-0 spikes and the repo lint
# tooling, and installs the versioned git hooks. Idempotent.
set -euo pipefail

echo "== Alloy bootstrap =="

if ! xcode-select -p >/dev/null 2>&1; then
  echo "ERROR: Xcode command-line tools missing. Run: xcode-select --install" >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew missing (https://brew.sh)" >&2
  exit 1
fi

# bison: Apple ships 2.3; Wine needs >= 3.0 (brew's is keg-only, prepend to PATH)
# lint stack for tools/lint.sh: shellcheck, shfmt, markdownlint-cli2, yamllint, swiftlint
BREW_DEPS=(bison meson ccache freetype gnutls shellcheck shfmt markdownlint-cli2 yamllint swiftlint)
MISSING=()
for dep in "${BREW_DEPS[@]}"; do
  brew list "$dep" >/dev/null 2>&1 || MISSING+=("$dep")
done
if ((${#MISSING[@]})); then
  echo "Installing: ${MISSING[*]}"
  brew install "${MISSING[@]}"
else
  echo "Homebrew deps present: ${BREW_DEPS[*]}"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$ROOT" config core.hooksPath tools/hooks
echo "git hooks: core.hooksPath -> tools/hooks"

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
