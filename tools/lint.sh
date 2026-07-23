#!/usr/bin/env bash
# Alloy repository linter
# Author: Tim Isaev
#
# Checks (default) or fixes (--fix) first-party sources against the repo
# style configs (.editorconfig, .clang-format, .markdownlint-cli2.yaml,
# .yamllint.yml, .swiftlint.yml).  Third-party checkouts, fetched
# toolchains, and spike work/ scratch are never touched — Wine patches
# follow Wine's upstream style by convention (see CODE_STYLE.md).
#
# Runs from any directory; used directly, by tools/hooks/pre-commit, and
# CI-callable.  Exit 0 = clean.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE=check
[[ "${1:-}" == "--fix" ]] && MODE=fix

TOOLCHAIN_BIN="$ROOT/tools/toolchains/llvm-mingw-20260616-ucrt-macos-universal/bin"
FAIL=0

note() { printf '== %s\n' "$*"; }
problem() {
  printf 'LINT: %s\n' "$*" >&2
  FAIL=1
}

need() { # tool [hint]
  if ! command -v "$1" >/dev/null 2>&1; then
    problem "$1 not installed${2:+ ($2)}; run tools/bootstrap.sh"
    return 1
  fi
}

# First-party tracked + staged files, one per line (repo has no spaces in
# paths; hook adds staged-new files so brand-new code is linted pre-commit).
files() { # extension-regex
  {
    git ls-files
    git diff --cached --name-only --diff-filter=AM 2>/dev/null || true
  } | sort -u |
    grep -Ev '^(third_party/|tools/toolchains/)' |
    grep -Ev '^spikes/[^/]+/work/' |
    grep -E "$1" || true
}

# --- C / C++ / Obj-C -------------------------------------------------------
C_FILES=$(files '\.(c|h|cpp|hpp|m|mm)$')
if [[ -n "$C_FILES" ]]; then
  CLANG_FORMAT="$TOOLCHAIN_BIN/clang-format"
  [[ -x "$CLANG_FORMAT" ]] || CLANG_FORMAT=clang-format
  if command -v "$CLANG_FORMAT" >/dev/null 2>&1; then
    note "clang-format ($MODE): $(echo "$C_FILES" | wc -l | tr -d ' ') file(s)"
    if [[ $MODE == fix ]]; then
      echo "$C_FILES" | xargs "$CLANG_FORMAT" -i
    else
      echo "$C_FILES" | xargs "$CLANG_FORMAT" --dry-run -Werror || problem "C formatting (tools/lint.sh --fix)"
    fi
  else
    problem "clang-format not found (toolchain missing; run tools/fetch-deps.sh)"
  fi
fi

# --- shell -----------------------------------------------------------------
SH_FILES=$(
  {
    files '\.sh$'
    files '^tools/hooks/'
  } | sort -u
)
if [[ -n "$SH_FILES" ]]; then
  if need shellcheck; then
    note "shellcheck: $(echo "$SH_FILES" | wc -l | tr -d ' ') file(s)"
    echo "$SH_FILES" | xargs shellcheck || problem "shellcheck findings"
  fi
  if need shfmt; then
    note "shfmt ($MODE)"
    if [[ $MODE == fix ]]; then
      echo "$SH_FILES" | xargs shfmt -i 2 -ci -w
    else
      echo "$SH_FILES" | xargs shfmt -i 2 -ci -d || problem "shell formatting (tools/lint.sh --fix)"
    fi
  fi
fi

# --- markdown --------------------------------------------------------------
if need markdownlint-cli2; then
  note "markdownlint ($MODE)"
  if [[ $MODE == fix ]]; then
    markdownlint-cli2 --fix >/dev/null 2>&1 || true
  fi
  markdownlint-cli2 || problem "markdown findings"
fi

# --- yaml ------------------------------------------------------------------
YAML_FILES=$(files '\.(yml|yaml)$')
if [[ -n "$YAML_FILES" ]] && need yamllint; then
  note "yamllint: $(echo "$YAML_FILES" | wc -l | tr -d ' ') file(s)"
  echo "$YAML_FILES" | xargs yamllint -c "$ROOT/.yamllint.yml" || problem "yaml findings"
fi

# --- json ------------------------------------------------------------------
JSON_FILES=$(files '\.json$')
if [[ -n "$JSON_FILES" ]] && need jq; then
  note "json validity: $(echo "$JSON_FILES" | wc -l | tr -d ' ') file(s)"
  while IFS= read -r f; do
    jq empty "$f" 2>/dev/null || problem "invalid JSON: $f"
  done <<<"$JSON_FILES"
fi

# --- swift (dormant until the app target lands) ----------------------------
SWIFT_FILES=$(files '\.swift$')
if [[ -n "$SWIFT_FILES" ]]; then
  if need swiftlint; then
    note "swiftlint ($MODE)"
    [[ $MODE == fix ]] && swiftlint --fix --quiet >/dev/null
    swiftlint lint --strict --quiet || problem "swift findings"
  fi
fi

if [[ $FAIL -eq 0 ]]; then
  note "lint OK"
else
  note "lint FAILED (tools/lint.sh --fix handles formatting; see CODE_STYLE.md)"
fi
exit $FAIL
