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
# --close-linked is the other half, run after the merge: it closes the issues
# the PR closes, because a merge made with the Actions token does not.
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
# query every night. PROJECT_TOKEN supplies that access; the header of
# auto-merge.yml says what kind of token it has to be, and why.
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
# The CI run that triggered this evaluation, so a hold can name the exact run to
# re-run. Optional: without it the comment points at the Checks tab instead.
CI_RUN_ID=${CI_RUN_ID-}
# Comments posted with the Actions GITHUB_TOKEN are authored by this login.
GATE_AUTHOR=${GATE_AUTHOR-github-actions[bot]}

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

gate_comment() { # reason-line [issue:field ...]
  local reason=$1 entry issue field estimate_missing=0 actual_issues=()
  shift

  printf '%s\n' "$COMMENT_MARKER"
  printf '**Auto-merge is holding this pull request.**\n\n'
  printf '%s\n' "$reason"

  if (($# > 0)); then
    printf '\n'
    for entry in "$@"; do
      issue=${entry%%:*}
      field=${entry#*:}
      case $field in
        Estimate)
          estimate_missing=1
          printf -- '- #%s `Estimate` — shaping estimate in hours, required before a task is picked up\n' "$issue"
          ;;
        Actual)
          actual_issues+=("$issue")
          printf -- '- #%s `Actual` — hours actually spent, required before a task reaches Done\n' "$issue"
          ;;
        *)
          printf -- '- #%s `%s`\n' "$issue" "$field"
          ;;
      esac
    done
  fi

  # finish-task.sh records Actual and nothing else, so it is offered only for an
  # issue that is short of Actual, and only for that issue. Pointing it at an
  # Estimate hold - or at the first issue of several - sends the reader round a
  # loop that never releases the PR.
  if ((estimate_missing)); then
    printf '\n`Estimate` has no helper: set it on the project board.\n'
  fi
  if ((${#actual_issues[@]})); then
    printf '\nRecord `Actual` with the finish helper. It preserves Estimate and re-runs\n'
    printf 'CI, which is what makes auto-merge look at this PR again:\n\n```sh\n'
    for issue in "${actual_issues[@]}"; do
      printf 'scripts/finish-task.sh %s <actual-hours>\n' "$issue"
    done
    printf '```\n'
  fi

  # Editing the board fires no repository event, so nothing re-runs the gate on
  # its own. Saying so is the difference between a hold that clears and one the
  # reader waits on indefinitely.
  printf '\nAuto-merge re-evaluates this PR each time its CI run completes; a change on\n'
  printf 'the board alone does not trigger that. After fixing anything by hand, re-run CI'
  if [[ -n $CI_RUN_ID ]]; then
    printf ':\n\n```sh\ngh run rerun %s --repo %s\n```\n\n' "$CI_RUN_ID" "$REPOSITORY"
  else
    printf ' from the Checks tab.\n\n'
  fi
  printf 'This comment is edited in place, never repeated.\n'
}

lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

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

gate_comment_id() { # -> id of this gate's own comment on the PR, empty if none
  # Matched on author as well as marker. A comment by anyone else that carries
  # the marker - pasted, or copied from the raw Markdown - must never be edited
  # or deleted as though the gate had written it.
  gh api "repos/${REPOSITORY}/issues/${NUMBER}/comments?per_page=100" \
    --paginate --slurp |
    jq -r --arg m "$COMMENT_MARKER" --arg a "$GATE_AUTHOR" '
      flatten
      | map(select(((.body // "") | contains($m)) and .user.login == $a))
      | last | .id // empty'
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

closing_refs() { # -> "owner/name number" per issue the PR closes
  # GitHub's own resolution of the closing keyword, rather than a second regex
  # that would drift from it. This is what scripts/finish-task.sh checks too,
  # so the two agree by construction on Fixes/Closes/Resolves and their variants.
  gh pr view "$NUMBER" --repo "$REPOSITORY" \
    --json closingIssuesReferences \
    --jq '.closingIssuesReferences[]
          | "\(.repository.owner.login)/\(.repository.name) \(.number)"'
}

close_linked() { # after the merge: close what the merge itself leaves open
  # A PR merged with the Actions token does not close its linked issues. Every
  # auto-merged task PR from #64 to #93 left its issue open, while the PRs
  # merged by hand in between closed theirs within two seconds - and #93 merged
  # with issues:write already granted, so the permission alone is not the cause.
  # Closing here is also what moves the card to Done.
  local refs repo number here state failed=0
  refs=$(closing_refs)
  here=$(lower "$REPOSITORY")

  while read -r repo number; do
    [[ -n $number && $(lower "$repo") == "$here" ]] || continue
    if ! state=$(gh issue view "$number" --repo "$REPOSITORY" --json state --jq .state); then
      printf 'Could not read issue #%s.\n' "$number" >&2
      failed=1
    elif [[ $state == CLOSED ]]; then
      printf 'Issue #%s is already closed.\n' "$number"
    elif gh issue close "$number" --repo "$REPOSITORY" --reason completed \
      --comment "Closed by #${NUMBER}, merged by auto-merge." >/dev/null; then
      printf 'Closed issue #%s.\n' "$number"
    else
      printf 'Could not close issue #%s.\n' "$number" >&2
      failed=1
    fi
  done <<<"$refs"

  # One issue that will not close must not leave the others open, and must not
  # pass quietly either: the PR is already merged, so a red run is the signal.
  return "$failed"
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

  check_lacks() { # name needle haystack
    local name=$1 needle=$2 haystack=$3
    cases=$((cases + 1))
    if [[ $haystack == *"$needle"* ]]; then
      printf 'FAIL %s: %q should not be in the comment body\n' "$name" "$needle" >&2
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
  body=$(gate_comment 'A reason.' 57:Actual)
  check_contains comment-marker "$COMMENT_MARKER" "$body"
  check_contains comment-names-field '#57 `Actual`' "$body"
  check_contains comment-points-at-helper 'scripts/finish-task.sh 57' "$body"

  # The helper cannot set Estimate, so an Estimate hold must not offer it.
  body=$(gate_comment 'A reason.' 76:Estimate)
  check_contains estimate-points-at-board 'set it on the project board' "$body"
  check_lacks estimate-omits-helper 'finish-task.sh' "$body"

  # Several issues: the helper is offered for the one short of Actual only.
  body=$(gate_comment 'A reason.' 57:Estimate 58:Actual)
  check_contains multi-names-short-issue 'scripts/finish-task.sh 58' "$body"
  check_lacks multi-omits-other-issue 'scripts/finish-task.sh 57' "$body"

  body=$(CI_RUN_ID=4242 REPOSITORY=o/r gate_comment 'A reason.' 57:Actual)
  check_contains names-the-run 'gh run rerun 4242 --repo o/r' "$body"

  # The unreadable-board case names no field, so it must not advertise a helper
  # that cannot fix it.
  body=$(gate_comment 'The board could not be read.')
  check_contains unreadable-has-marker "$COMMENT_MARKER" "$body"
  check_lacks unreadable-omits-helper 'finish-task.sh' "$body"

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
  local mode=${1:-}
  if (($# > 1)) || [[ -n $mode && $mode != --close-linked ]]; then
    printf 'usage: %s [--selftest | --close-linked]\n' "$0" >&2
    return 2
  fi

  : "${NUMBER:?NUMBER is required}"
  : "${REPOSITORY:?REPOSITORY is required}"
  : "${GH_TOKEN:?GH_TOKEN is required}"
  if [[ ! $NUMBER =~ ^[0-9]+$ ]]; then
    printf 'NUMBER must be numeric: %q\n' "$NUMBER" >&2
    return 2
  fi

  if [[ $mode == --close-linked ]]; then
    close_linked
    return
  fi

  local refs
  refs=$(closing_refs)

  if [[ -z $refs ]]; then
    printf 'PR #%s closes no issue; not a task PR, board gate does not apply.\n' "$NUMBER"
    return "$ALLOW"
  fi

  # The board is read through this repository's issues. A reference elsewhere
  # (`Fixes other/repo#5`) would otherwise be looked up as this repository's #5,
  # an unrelated issue, so it is held rather than checked against the wrong one.
  local repo number here closes="" foreign=()
  here=$(lower "$REPOSITORY")
  while read -r repo number; do
    if [[ $(lower "$repo") == "$here" ]]; then
      closes+="${closes:+ }$number"
    else
      foreign+=("$repo#$number")
    fi
  done <<<"$refs"
  printf 'PR #%s closes: %s\n' "$NUMBER" "${refs//$'\n'/, }"

  if ((${#foreign[@]})); then
    upsert_comment "$(gate_comment "This PR closes an issue outside this repository (${foreign[*]}). The
board gate can only check this repository's issues, so it holds rather than
guess. Merge by hand if that is intended.")"
    printf 'Closes an issue outside %s; holding PR #%s.\n' "$REPOSITORY" "$NUMBER" >&2
    return "$HOLD"
  fi

  if [[ -z $PROJECT_TOKEN ]]; then
    upsert_comment "$(gate_comment \
      'The project board could not be read, so the required fields could not be
verified. The `PROJECT_TOKEN` secret is not set on this repository. Auto-merge
holds task PRs rather than waving them through when the board is unreadable.')"
    printf 'PROJECT_TOKEN is not set; holding PR #%s.\n' "$NUMBER" >&2
    return "$HOLD"
  fi

  local issue item missing field entries=() unreadable=()
  for issue in $closes; do
    # Every step is status-checked. The field check used to feed a while loop
    # through a process substitution, whose exit status bash discards, so a jq
    # that died part-way read as "nothing missing" and merged the PR.
    if ! item=$(board_item "$issue") || [[ -z $item ]] ||
      ! missing=$(missing_fields "$item"); then
      unreadable+=("$issue")
      continue
    fi
    if [[ -z $missing ]]; then
      printf 'Issue #%s has Estimate and Actual recorded.\n' "$issue"
      continue
    fi
    printf 'Issue #%s is missing: %s\n' "$issue" "${missing//$'\n'/ }"
    while IFS= read -r field; do
      [[ -n $field ]] && entries+=("$issue:$field")
    done <<<"$missing"
  done

  if ((${#unreadable[@]})); then
    local list
    list=$(printf '#%s, ' "${unreadable[@]}")
    upsert_comment "$(gate_comment "Board item(s) for ${list%, } could not be read from project ${PROJECT_NUMBER}.
Either the item is not on the board, or \`PROJECT_TOKEN\` lacks the access to see
it. Auto-merge holds task PRs rather than waving them through when the board is
unreadable.")"
    printf 'Board unreadable for: %s; holding PR #%s.\n' "${unreadable[*]}" "$NUMBER" >&2
    return "$HOLD"
  fi

  if ((${#entries[@]})); then
    upsert_comment "$(gate_comment \
      'This PR closes an issue whose board item is missing a required field:' \
      "${entries[@]}")"
    printf 'Holding PR #%s on: %s\n' "$NUMBER" "${entries[*]}"
    return "$HOLD"
  fi

  clear_comment
  printf 'Board fields recorded for every closed issue; merge may proceed.\n'
  return "$ALLOW"
}

main "$@"
