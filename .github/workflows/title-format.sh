#!/usr/bin/env bash
# Normalize Alloy issue titles and provide a network-free self-test.
# Author: Timur Isaev
set -euo pipefail

readonly COMMENT_MARKER='<!-- title-format:missing-domain -->'

# These are populated by the workflow; defaults keep the pure self-test offline.
NUMBER=${NUMBER-}
REPOSITORY=${REPOSITORY-}
GH_TOKEN=${GH_TOKEN-}

RESULT=
RESULT_TITLE=

derive_title() { # issue-number current-title labels-json
  local number=$1
  local title=$2
  local labels_json=$3
  local conforming_re legacy_re stale_re
  local domain label rest

  conforming_re="^\\[[a-z0-9]+-${number}\\]: "
  if [[ $title =~ $conforming_re ]]; then
    RESULT=conforming
    RESULT_TITLE=$title
    return
  fi

  domain=
  rest=$title
  legacy_re='^([A-Za-z0-9]+)(/[A-Za-z0-9]+)*: (.*)$'
  if [[ $title =~ $legacy_re ]]; then
    domain=$(printf '%s' "${BASH_REMATCH[1]}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    rest=${BASH_REMATCH[3]}
  else
    label=$(jq -r '[.[] | select(startswith("area:"))][0] // empty' <<<"$labels_json")
    if [[ -n $label ]]; then
      domain=$(
        printf '%s' "${label#area:}" |
          LC_ALL=C tr '[:upper:]' '[:lower:]' |
          LC_ALL=C tr -cd 'a-z0-9'
      )

      # Preserve the summary when correcting a title that carries another
      # issue's number instead of nesting the stale prefix in the new title.
      stale_re='^\[[A-Za-z0-9]+-[0-9]+\]: (.*)$'
      if [[ $title =~ $stale_re ]]; then
        rest=${BASH_REMATCH[1]}
      fi
    fi
  fi

  if [[ -z $domain ]]; then
    RESULT=missing
    RESULT_TITLE=$title
    return
  fi

  RESULT=normalize
  RESULT_TITLE="[${domain}-${number}]: ${rest}"
}

comment_for_shaping() {
  local existing comment

  existing=$(
    gh api "repos/${REPOSITORY}/issues/${NUMBER}/comments?per_page=100" \
      --paginate --slurp |
      jq 'flatten | map(select((.body // "") | contains("<!-- title-format:missing-domain -->"))) | length'
  )
  if ((existing > 0)); then
    printf 'No title domain; the shaping comment already exists.\n'
    return
  fi

  comment="${COMMENT_MARKER}
This issue needs title shaping. Add a legacy \`DOMAIN: summary\` prefix or an \`area:*\` label, then edit or reopen the issue so its title can be normalized."
  gh issue comment "$NUMBER" --repo "$REPOSITORY" --body "$comment" >/dev/null
  printf 'No title domain; requested shaping once.\n'
}

run_selftest() {
  local failures=0
  local cases=0
  local literal_shell_text="\$(touch should-not-run)"

  check() { # name expected-result expected-title number title labels-json
    local name=$1
    local expected_result=$2
    local expected_title=$3
    local number=$4
    local title=$5
    local labels_json=$6

    cases=$((cases + 1))
    derive_title "$number" "$title" "$labels_json"
    if [[ $RESULT != "$expected_result" || $RESULT_TITLE != "$expected_title" ]]; then
      printf 'FAIL %s: got result=%q title=%q\n' "$name" "$RESULT" "$RESULT_TITLE" >&2
      failures=$((failures + 1))
    fi
  }

  check conforming conforming '[cpu-42]: something' \
    42 '[cpu-42]: something' '["area:cpu"]'
  check legacy normalize '[cpu-42]: something' \
    42 'CPU: something' '[]'
  check legacy-subdomain normalize '[gfx-42]: shader work' \
    42 'GFX/SHADER: shader work' '[]'
  check first-area normalize '[ci-42]: plain summary' \
    42 'plain summary' '["priority:P2","area:ci","area:tools"]'
  check sanitized-area normalize '[thirdparty-42]: audit' \
    42 'audit' '["area:third-party"]'
  check stale-number normalize '[cpu-42]: preserved summary' \
    42 '[gpu-9]: preserved summary' '["area:cpu"]'
  check literal-shell-text normalize "[cpu-42]: ${literal_shell_text}" \
    42 "CPU: ${literal_shell_text}" '[]'
  check missing missing 'unshaped summary' \
    42 'unshaped summary' '["priority:P2"]'

  if ((failures > 0)); then
    printf 'title-format self-test: %d of %d case(s) failed\n' "$failures" "$cases" >&2
    return 1
  fi
  printf 'title-format self-test: %d case(s) passed\n' "$cases"
}

main() {
  local issue_json title labels_json

  if [[ ${1:-} == --selftest ]]; then
    run_selftest
    return
  fi
  if (($# > 0)); then
    printf 'usage: %s [--selftest]\n' "$0" >&2
    return 2
  fi

  : "${NUMBER:?NUMBER is required}"
  : "${REPOSITORY:?REPOSITORY is required}"
  : "${GH_TOKEN:?GH_TOKEN is required}"
  if [[ ! $NUMBER =~ ^[0-9]+$ ]]; then
    printf 'NUMBER must be numeric: %q\n' "$NUMBER" >&2
    return 2
  fi

  # Read the live issue rather than trusting a queued event's stale title.
  # Event titles and labels are untrusted input and never become shell code.
  issue_json=$(gh issue view "$NUMBER" --repo "$REPOSITORY" --json title,labels)
  title=$(jq -r '.title' <<<"$issue_json")
  labels_json=$(jq -c '[.labels[].name]' <<<"$issue_json")
  derive_title "$NUMBER" "$title" "$labels_json"

  case $RESULT in
    conforming)
      printf 'Title already conforms: %s\n' "$title"
      ;;
    missing)
      comment_for_shaping
      ;;
    normalize)
      gh issue edit "$NUMBER" --repo "$REPOSITORY" --title "$RESULT_TITLE" >/dev/null
      printf 'Normalized title: %s\n' "$RESULT_TITLE"
      ;;
    *)
      printf 'Unexpected normalization result: %q\n' "$RESULT" >&2
      return 2
      ;;
  esac
}

main "$@"
