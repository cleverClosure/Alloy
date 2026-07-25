#!/usr/bin/env bash
# Refuse to auto-merge a task PR whose board item is missing a required field.
# Author: Tim Isaev
#
# Three tasks reached Done on 25 July 2026 with no Actual recorded, hours after
# the same gap had been flagged. scripts/finish-task.sh sets the field, but a
# helper only runs when someone remembers to run it. Auto-merge is where the
# decision to land a task actually happens, so the gate lives here: a PR that
# closes a board item does not merge until that item's Estimate and Actual are
# both set.
#
# Scope is deliberately narrow. A PR with no closing reference - a docs or
# process PR - is not a task and merges exactly as before. Drafts never reach
# this script; auto-merge.yml returns earlier.
#
# The gate fails closed. If the board cannot be read at all (no token, expired
# token, API error) the PR is held rather than waved through, because a gate
# that disappears when its credential expires is the failure mode this task
# exists to end. That choice has a cost: an expired PROJECT_TOKEN stalls every
# task PR until it is renewed. The stall is loud and self-describing, which is
# the point - the alternative fails silently back to the behaviour that lost
# three Actual values in one day.
#
# Reading the board needs a credential the workflow does not get for free. The
# Actions GITHUB_TOKEN cannot resolve a user-owned ProjectV2 at all: the API
# answers NOT_FOUND rather than a permission error, which is how the nightly
# board linter in .github/workflows/board-lint.yml came to fail on its first
# query every night. PROJECT_TOKEN is a fine-grained PAT supplying that access;
# see the header of auto-merge.yml for exactly which permissions it needs.
#
# shellcheck disable=SC2016
# The comment this script posts is Markdown, so `Estimate`, `Actual` and
# `PROJECT_TOKEN` are backtick-quoted for GitHub rather than shell expansions,
# and every printf format is single-quoted precisely so nothing expands.
set -euo pipefail

readonly COMMENT_MARKER='<!-- auto-merge:board-fields -->'
readonly PROJECT_NUMBER=1

# Exit status. Anything non-zero holds the PR, so an unexpected failure under
# `set -e` is already fail-closed; HOLD just names the deliberate case.
readonly ALLOW=0
readonly HOLD=10

# Populated by the workflow. The defaults keep --selftest offline.
NUMBER=${NUMBER-}
REPOSITORY=${REPOSITORY-}
GH_TOKEN=${GH_TOKEN-}
PROJECT_TOKEN=${PROJECT_TOKEN-}

# ── pure logic ────────────────────────────────────────────────────────────────
# Split from the API calls so the self-test can cover the decisions rather than
# the plumbing, exactly as title-format.sh does.

missing_fields() { # board-item-json -> one field name per line, empty if fine
  # A ProjectV2 number field that is unset comes back as a null node, so the
  # whole `.estimate` object is null and `.estimate.number` is null with it.
  # Zero is a legitimately recorded value and must not read as missing - jq's
  # `//` treats 0 as present, unlike a truthiness test in most other languages.
  jq -r '
    [ {name: "Estimate", value: .estimate.number},
      {name: "Actual",   value: .actual.number}
    ]
    | map(select(.value == null) | .name)
    | .[]' <<<"$1"
}

gate_comment() { # issue-number reason-line [field ...]
  local issue=$1 reason=$2
  shift 2

  printf '%s\n' "$COMMENT_MARKER"
  printf '**Auto-merge is holding this pull request.**\n\n'
  printf '%s\n\n' "$reason"

  local field
  for field in "$@"; do
    case $field in
      Estimate)
        printf -- '- `Estimate` — shaping estimate in hours, required before a task is picked up\n'
        ;;
      Actual)
        printf -- '- `Actual` — hours actually spent, required before a task reaches Done\n'
        ;;
      *)
        printf -- '- `%s`\n' "$field"
        ;;
    esac
  done

  if (($# > 0)); then
    printf '\nSet it with the finish helper, which preserves Estimate rather than\n'
    printf 'overwriting it:\n\n'
    printf '```sh\nscripts/finish-task.sh %s <actual-hours>\n```\n\n' "$issue"
  fi

  printf 'Nothing else is required: CI is already green, and auto-merge re-evaluates\n'
  printf 'this PR on its next run. This comment is edited in place, never repeated.\n'
}

# ── the board ─────────────────────────────────────────────────────────────────

board_item() { # issue-number -> the project item JSON, or empty on any failure
  local issue=$1 raw

  # shellcheck disable=SC2016 # $vars in the query are GraphQL variables, not shell
  raw=$(GH_TOKEN="$PROJECT_TOKEN" gh api graphql \
    -f owner="${REPOSITORY%%/*}" -f name="${REPOSITORY##*/}" -F number="$issue" \
    -f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      projectItems(first: 20) {
        nodes {
          project { number }
          estimate: fieldValueByName(name: "Estimate") {
            ... on ProjectV2ItemFieldNumberValue { number }
          }
          actual: fieldValueByName(name: "Actual") {
            ... on ProjectV2ItemFieldNumberValue { number }
          }
        }
      }
    }
  }
}' 2>/dev/null) || return 1

  # A token without ProjectV2 access still returns HTTP 200, with the field
  # nulled and an error alongside it. Treat that as unreadable, not as absent.
  jq -e --argjson proj "$PROJECT_NUMBER" '
    .data.repository.issue.projectItems.nodes
    | map(select(.project.number == $proj))
    | .[0] // empty' <<<"$raw" 2>/dev/null
}

gate_comment_id() { # -> id of this gate's comment on the PR, empty if none
  gh api "repos/${REPOSITORY}/issues/${NUMBER}/comments?per_page=100" \
    --paginate --slurp |
    jq -r --arg m "$COMMENT_MARKER" \
      'flatten | map(select((.body // "") | contains($m))) | last | .id // empty'
}

upsert_comment() { # body
  local body=$1 existing current

  existing=$(gate_comment_id)

  if [[ -z $existing ]]; then
    gh issue comment "$NUMBER" --repo "$REPOSITORY" --body "$body" >/dev/null
    printf 'Explained the hold on PR #%s (one comment).\n' "$NUMBER"
    return
  fi

  # Edit in place when the reason changed - setting Estimate while Actual is
  # still empty must not leave a comment naming the wrong field - and stay
  # silent when it did not, so polling generates no notifications.
  current=$(gh api "repos/${REPOSITORY}/issues/comments/${existing}" --jq .body)
  if [[ $current == "$body" ]]; then
    printf 'Hold already explained on PR #%s; comment unchanged.\n' "$NUMBER"
    return
  fi
  gh api -X PATCH "repos/${REPOSITORY}/issues/comments/${existing}" \
    -f body="$body" >/dev/null
  printf 'Hold reason changed on PR #%s; edited the existing comment.\n' "$NUMBER"
}

clear_comment() {
  # A hold that has been satisfied leaves no trace, the same way board-lint.yml
  # removes its report once the board is clean. Otherwise every task PR merges
  # carrying a comment that still says it is being held, which reads as a
  # standing objection to anyone who finds the PR later.
  local existing
  existing=$(gate_comment_id)
  [[ -z $existing ]] && return 0

  gh api -X DELETE "repos/${REPOSITORY}/issues/comments/${existing}" >/dev/null
  printf 'Hold cleared on PR #%s; removed the explanation.\n' "$NUMBER"
}

# ── self-test ─────────────────────────────────────────────────────────────────

run_selftest() {
  local failures=0 cases=0

  check_missing() { # name expected-newline-separated-fields item-json
    local name=$1 expected=$2 item=$3 got
    cases=$((cases + 1))
    got=$(missing_fields "$item")
    if [[ $got != "$expected" ]]; then
      printf 'FAIL %s: expected %q, got %q\n' "$name" "$expected" "$got" >&2
      failures=$((failures + 1))
    fi
  }

  check_contains() { # name needle haystack
    local name=$1 needle=$2 haystack=$3
    cases=$((cases + 1))
    if [[ $haystack != *"$needle"* ]]; then
      printf 'FAIL %s: %q missing from the comment body\n' "$name" "$needle" >&2
      failures=$((failures + 1))
    fi
  }

  check_missing both-set '' \
    '{"estimate":{"number":3},"actual":{"number":4}}'
  check_missing actual-unset 'Actual' \
    '{"estimate":{"number":3},"actual":null}'
  check_missing estimate-unset 'Estimate' \
    '{"estimate":null,"actual":{"number":4}}'
  check_missing both-unset 'Estimate
Actual' '{"estimate":null,"actual":null}'

  # Zero hours is a recorded value, not an empty field. A truthiness test here
  # would hold a PR forever on a task that genuinely took no measurable time.
  check_missing actual-zero '' \
    '{"estimate":{"number":3},"actual":{"number":0}}'
  check_missing estimate-zero '' \
    '{"estimate":{"number":0},"actual":{"number":0}}'

  # Absent keys behave like explicit nulls, so a schema change cannot silently
  # turn the gate into a no-op.
  check_missing keys-absent 'Estimate
Actual' '{}'

  local body
  body=$(gate_comment 57 'A reason.' Actual)
  check_contains comment-marker "$COMMENT_MARKER" "$body"
  check_contains comment-names-field '`Actual`' "$body"
  check_contains comment-points-at-helper 'scripts/finish-task.sh 57' "$body"

  # The unreadable-board case names no field, so it must not advertise a helper
  # that cannot fix it.
  body=$(gate_comment 57 'The board could not be read.')
  check_contains unreadable-has-marker "$COMMENT_MARKER" "$body"
  cases=$((cases + 1))
  if [[ $body == *'finish-task.sh'* ]]; then
    printf 'FAIL unreadable-omits-helper: suggested the helper for a token fault\n' >&2
    failures=$((failures + 1))
  fi

  if ((failures > 0)); then
    printf 'merge-gate self-test: %d of %d case(s) failed\n' "$failures" "$cases" >&2
    return 1
  fi
  printf 'merge-gate self-test: %d case(s) passed\n' "$cases"
}

# ── entry point ───────────────────────────────────────────────────────────────

main() {
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

  # GitHub's own resolution of the closing keyword, rather than a second regex
  # that would drift from it. This is what actually closes the issue on merge,
  # and it is what scripts/finish-task.sh checks, so the two agree by
  # construction on Fixes/Closes/Resolves and their variants.
  local closes
  closes=$(gh pr view "$NUMBER" --repo "$REPOSITORY" \
    --json closingIssuesReferences \
    --jq '[.closingIssuesReferences[].number] | join(" ")')

  if [[ -z $closes ]]; then
    printf 'PR #%s closes no issue; not a task PR, board gate does not apply.\n' "$NUMBER"
    return "$ALLOW"
  fi
  printf 'PR #%s closes: %s\n' "$NUMBER" "$closes"

  if [[ -z $PROJECT_TOKEN ]]; then
    upsert_comment "$(gate_comment "${closes%% *}" \
      'The project board could not be read, so the required fields could not be
verified. The `PROJECT_TOKEN` secret is not set on this repository. Auto-merge
holds task PRs rather than waving them through when the board is unreadable.')"
    printf 'PROJECT_TOKEN is not set; holding PR #%s.\n' "$NUMBER" >&2
    return "$HOLD"
  fi

  local issue item field unique_field fields all_missing=() unreadable=()
  for issue in $closes; do
    if ! item=$(board_item "$issue") || [[ -z $item ]]; then
      unreadable+=("$issue")
      continue
    fi
    fields=()
    while IFS= read -r field; do
      [[ -n $field ]] && fields+=("$field")
    done < <(missing_fields "$item")
    if ((${#fields[@]})); then
      printf 'Issue #%s is missing: %s\n' "$issue" "${fields[*]}"
      all_missing+=("${fields[@]}")
    else
      printf 'Issue #%s has Estimate and Actual recorded.\n' "$issue"
    fi
  done

  if ((${#unreadable[@]})); then
    upsert_comment "$(gate_comment "${unreadable[0]}" \
      "Issue #${unreadable[0]} could not be read from project ${PROJECT_NUMBER}. Either the
item is not on the board, or \`PROJECT_TOKEN\` lacks the access to see it.
Auto-merge holds task PRs rather than waving them through when the board is
unreadable.")"
    printf 'Board unreadable for: %s; holding PR #%s.\n' "${unreadable[*]}" "$NUMBER" >&2
    return "$HOLD"
  fi

  if ((${#all_missing[@]})); then
    # De-duplicate while keeping first-seen order, so a PR closing two issues
    # short of the same field describes it once and still reads Estimate before
    # Actual. `sort -u` would reorder them alphabetically into the opposite.
    local unique=() seen
    for field in "${all_missing[@]}"; do
      seen=0
      for unique_field in ${unique[@]+"${unique[@]}"}; do
        [[ $unique_field == "$field" ]] && seen=1 && break
      done
      ((seen)) || unique+=("$field")
    done
    all_missing=("${unique[@]}")
    upsert_comment "$(gate_comment "${closes%% *}" \
      "This PR closes an issue whose board item is missing a required field:" \
      "${all_missing[@]}")"
    printf 'Holding PR #%s on: %s\n' "$NUMBER" "${all_missing[*]}"
    return "$HOLD"
  fi

  clear_comment
  printf 'Board fields recorded for every closed issue; merge may proceed.\n'
  return "$ALLOW"
}

main "$@"
