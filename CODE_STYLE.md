# Alloy Code Style

**Author:** Tim Isaev
**Enforced by:** `tools/lint.sh` (run on every commit via the versioned
`tools/hooks/pre-commit`; installed by `tools/bootstrap.sh`).

One command to check, one to repair:

```sh
tools/lint.sh        # check everything (what the pre-commit hook runs)
tools/lint.sh --fix  # apply formatters, then re-check
```

## Scope boundary — the most important rule

Linters apply to **first-party code only**. Excluded always:

| Path | Why |
|------|-----|
| `third_party/**` | Upstream checkouts. **Wine patches follow Wine's upstream style** (match the surrounding code by hand; `third_party/.clang-format` disables formatting there so no tool ever rewrites upstream files). FEX is founder-only per its in-tree contribution policy. |
| `tools/toolchains/**` | Fetched release binaries. |
| `spikes/*/work/**` | Build artifacts and scratch; untracked. |

## Languages and rules

- **C / C++ / Obj-C** — `.clang-format` (LLVM base, 4-space indent, Allman
  braces, 100 columns, `void *p` pointer style, include order preserved —
  Windows headers are order-sensitive). Formatter binary comes from the
  pinned llvm-mingw toolchain, so its version rides the toolchain pin.
- **Shell** — bash only (`#!/usr/bin/env bash`, `set -euo pipefail`);
  zsh is not used because shellcheck cannot analyze it. `shellcheck` clean,
  `shfmt -i 2 -ci` formatting (2-space indent).
- **Markdown** — `.markdownlint-cli2.yaml`. The config codifies the docs
  package's established voice (no line-length cap, tight heading spacing,
  per-section H1s, inline HTML in tables, bare URLs); hygiene rules stay on
  (trailing spaces, tabs, blank-line runs, fenced-code language tags,
  spacing around fences/lists).
- **YAML** — `.yamllint.yml` (relaxed default: no line-length,
  no document-start marker).
- **JSON** — must parse (`jq empty`); schemas carry their own validation.
- **Swift** — `.swiftlint.yml` is in place and dormant; `tools/lint.sh`
  activates it automatically when the first `.swift` file lands
  (Alloy.app). 120-column warning, additive opt-in rules.
- **Everything** — `.editorconfig`: UTF-8, LF, final newline, no trailing
  whitespace (markdown excepted — hard-breaks are trailing double-spaces,
  policed by markdownlint instead).

## Workflow

- The pre-commit hook runs the full lint (~2 s). If it fails on
  formatting, `tools/lint.sh --fix && git add -u` and commit again.
- `git commit --no-verify` is for genuine emergencies only; fix and amend
  immediately after.
- New files carry an `Author: Tim Isaev` header where the format allows
  comments.
- The lint script is CI-callable as-is (exit code discipline); wire it
  into CI unchanged when remote CI exists.

## Changing the rules

Rule changes are normal engineering changes: edit the config, run
`tools/lint.sh` across the tree, include any resulting reformat in the
same commit, and note the rationale in the commit message.
