#!/usr/bin/env bash
# finish-task.sh — the finish gates for a board task
# Author: Tim Isaev
#
# Claiming has enforced gates (scripts/next-task.sh); finishing did not, and the
# board audit on 25 July 2026 found Actual empty on every item. This closes that
# end: Actual is set here, the closing keyword is checked before a draft is
# allowed to go ready, and closure is reconciled after the merge.
#
# Usage:
#   scripts/finish-task.sh <issue> <actual-hours>          # set Actual, check the PR
#   scripts/finish-task.sh <issue> <actual-hours> --ready  # ...and mark the draft ready
#   scripts/finish-task.sh <issue> --reconcile             # post-merge closure only
#
# Why the closing keyword is checked here rather than at merge time: it has been
# missed once already (the doc fix in PR #42) and deliberately dodged once (#43),
# and opening a ready PR is this repo's decision to merge. A keyword that is
# wrong is discovered after the branch is gone.
#
# Why closure is reconciled rather than trusted: on 25 July 2026 two PRs merged
# with a correct "Fixes #25" in the body and the issue stayed open both times.
# The likely cause is that .github/workflows/auto-merge.yml grants the Actions
# token contents:write and pull-requests:write but not issues:write, so the
# merge cannot close the linked issue. That file is area:ci and out of scope
# here; this script makes the end state correct either way and reports what it
# had to fix, so the underlying bug stays visible instead of being papered over.
set -euo pipefail

OWNER="cleverClosure"
REPO="Alloy"
PROJECT=1

usage() {
  sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'
}

issue="${1:-}"
issue="${issue#\#}"
case "$issue" in
  "" | -h | --help)
    usage
    exit 0
    ;;
esac
if [[ ! $issue =~ ^[0-9]+$ ]]; then
  echo "error: issue must be a number" >&2
  usage >&2
  exit 2
fi

actual=""
reconcile_only=0
mark_ready=0
for arg in "${@:2}"; do
  case "$arg" in
    --reconcile) reconcile_only=1 ;;
    --ready) mark_ready=1 ;;
    *)
      if [[ $arg =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        actual="$arg"
      else
        echo "error: unrecognized argument '$arg'" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done
if ((reconcile_only == 0)) && [[ -z $actual ]]; then
  echo "error: actual hours required (a number), or pass --reconcile" >&2
  usage >&2
  exit 2
fi

fail=0
note() { printf '  %s\n' "$*"; }
bad() {
  printf '  FAIL: %s\n' "$*" >&2
  fail=1
}

# ── the board item ────────────────────────────────────────────────────────────
# shellcheck disable=SC2016 # $vars in the query are GraphQL variables, not shell
raw=$(gh api graphql -f owner="$OWNER" -f name="$REPO" -F number="$issue" -f query='
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      state
      title
      projectItems(first: 10) {
        nodes {
          id
          project { number id }
          status: fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
          agent: fieldValueByName(name: "Agent") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
          estimate: fieldValueByName(name: "Estimate") {
            ... on ProjectV2ItemFieldNumberValue { number }
          }
        }
      }
    }
  }
}')

item=$(jq --argjson proj "$PROJECT" '
  .data.repository.issue as $i
  | ($i.projectItems.nodes | map(select(.project.number == $proj)) | .[0]) as $it
  | {state: $i.state, title: $i.title, item_id: ($it.id // ""), project_id: ($it.project.id // ""),
     status: ($it.status.name // ""), agent: ($it.agent.name // ""), estimate: ($it.estimate.number // null)}' <<<"$raw")

item_id=$(jq -r '.item_id' <<<"$item")
project_id=$(jq -r '.project_id' <<<"$item")
if [[ -z $item_id ]]; then
  echo "error: issue #$issue is not on project $PROJECT — add it before finishing" >&2
  exit 1
fi

echo "== #$issue $(jq -r '.title' <<<"$item")"
note "status $(jq -r '.status' <<<"$item"), agent $(jq -r '.agent // "unset"' <<<"$item"), estimate $(jq -r '.estimate // "unset"' <<<"$item")h"

fields=$(gh project field-list "$PROJECT" --owner "$OWNER" --format json)
field_id() { jq -r --arg f "$1" '.fields[] | select(.name == $f) | .id' <<<"$fields"; }
option_id() { jq -r --arg f "$1" --arg o "$2" '.fields[] | select(.name == $f) | .options[] | select(.name == $o) | .id' <<<"$fields"; }

set_number() { # field-name numeric-value
  # shellcheck disable=SC2016 # $vars are GraphQL variables; the number is inlined
  gh api graphql -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$(field_id "$1")" \
    -f query="
mutation(\$projectId: ID!, \$itemId: ID!, \$fieldId: ID!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: \$projectId, itemId: \$itemId, fieldId: \$fieldId, value: {number: $2}
  }) { projectV2Item { id } }
}" >/dev/null
}

set_option() { # field-name option-name
  # shellcheck disable=SC2016 # $vars in the query are GraphQL variables, not shell
  gh api graphql -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$(field_id "$1")" \
    -f optionId="$(option_id "$1" "$2")" -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
    value: { singleSelectOptionId: $optionId }
  }) { projectV2Item { id } }
}' >/dev/null
}

# ── 1. Actual ─────────────────────────────────────────────────────────────────
if ((reconcile_only == 0)); then
  echo "== 1. Actual"
  # Estimate is never overwritten here. Copying Estimate into Actual as a
  # placeholder destroys the only comparison the two fields exist to support.
  set_number Actual "$actual"
  note "Actual = ${actual}h (Estimate $(jq -r '.estimate // "unset"' <<<"$item")h, preserved)"
fi

# ── 2. the pull request and its closing keyword ───────────────────────────────
echo "== 2. pull request"
prs=$(gh pr list --repo "$OWNER/$REPO" --state all --limit 100 \
  --json number,state,isDraft,body,title,headRefName,headRefOid,url,closingIssuesReferences \
  --jq "map(select((.closingIssuesReferences | map(.number) | index($issue)) != null
        or (.headRefName | startswith(\"task/$issue-\"))))")
pr_count=$(jq -r 'length' <<<"$prs")

if ((pr_count == 0)); then
  note "no pull request found for #$issue yet"
else
  pr=$(jq -r '. as $all | ($all | map(select(.state == "OPEN")) | .[0]) // ($all | .[0])' <<<"$prs")
  pr_num=$(jq -r '.number' <<<"$pr")
  pr_state=$(jq -r '.state' <<<"$pr")
  pr_draft=$(jq -r '.isDraft' <<<"$pr")
  note "PR #$pr_num ($pr_state$([[ $pr_draft == true ]] && echo ", draft"))"

  # GitHub honours closing keywords in the PR description only. A keyword that
  # appears solely in the title looks right in the list view and closes nothing.
  keyword='(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#'"$issue"'([^0-9]|$)'
  if jq -r '.body' <<<"$pr" | grep -Eiq "$keyword"; then
    note "closing keyword found in the body"
  elif jq -r '.title' <<<"$pr" | grep -Eiq "$keyword"; then
    bad "closing keyword is in the PR title but not the body — GitHub reads the body"
    note "add a line to the body:  Fixes #$issue"
  else
    bad "no closing keyword for #$issue in PR #$pr_num"
    note "add a line to the body:  Fixes #$issue"
  fi

  if ((mark_ready)); then
    if ((fail)); then
      bad "not marking PR #$pr_num ready while the closing keyword is missing"
    elif [[ $pr_draft != true ]]; then
      note "PR #$pr_num is already ready"
    else
      gh pr ready "$pr_num" --repo "$OWNER/$REPO" >/dev/null
      note "PR #$pr_num marked ready — auto-merge will squash it once CI is green"
    fi
  fi

  # Setting a board field fires no repository event, and auto-merge only looks
  # at a PR when its CI run completes. A PR that was already ready - one the
  # board gate may be holding for this very field - is re-evaluated by
  # re-running its latest CI run. A draft marked ready above needs nothing:
  # ci.yml runs on ready_for_review.
  if ((reconcile_only == 0 && fail == 0)) && [[ $pr_state == OPEN && $pr_draft != true ]]; then
    head_sha=$(jq -r '.headRefOid' <<<"$pr")
    ci_run=$(gh run list --repo "$OWNER/$REPO" --workflow ci.yml --event pull_request \
      --commit "$head_sha" --limit 1 --json databaseId,status \
      --jq '.[0] // empty | "\(.databaseId) \(.status)"')
    if [[ -z $ci_run ]]; then
      note "no CI run found for ${head_sha:0:7} — push or re-run CI so auto-merge re-evaluates"
    elif [[ ${ci_run#* } == completed ]]; then
      gh run rerun "${ci_run%% *}" --repo "$OWNER/$REPO" >/dev/null
      note "re-ran CI run ${ci_run%% *} so auto-merge re-evaluates PR #$pr_num"
    else
      note "CI run ${ci_run%% *} is ${ci_run#* } — auto-merge evaluates PR #$pr_num when it completes"
    fi
  fi
fi

# ── 3. closure reconciliation ─────────────────────────────────────────────────
# Only meaningful once the PR has merged; before that, an open issue is correct.
echo "== 3. closure"
merged=0
if ((pr_count > 0)) && [[ $(jq -r '.state' <<<"$pr") == MERGED ]]; then merged=1; fi

if ((merged == 0)); then
  note "PR not merged yet — leaving issue and card alone"
else
  issue_state=$(gh issue view "$issue" --repo "$OWNER/$REPO" --json state --jq '.state')
  if [[ $issue_state == CLOSED ]]; then
    note "issue #$issue is closed"
  else
    gh issue close "$issue" --repo "$OWNER/$REPO" --reason completed \
      --comment "Closed by #$(jq -r '.number' <<<"$pr"). The merge did not close it automatically; \`scripts/finish-task.sh\` reconciled it." >/dev/null
    note "issue #$issue was still OPEN after merge — closed it (see the header note on auto-merge permissions)"
  fi

  status_now=$(gh project item-list "$PROJECT" --owner "$OWNER" --format json --limit 200 |
    jq -r --argjson n "$issue" '.items[] | select(.content.number == $n) | .status // ""')
  if [[ $status_now == Done ]]; then
    note "card is Done"
  else
    set_option Status Done
    note "card was $status_now — moved to Done"
  fi
fi

echo
if ((fail == 0)); then
  echo "FINISH: ok"
else
  echo "FINISH: incomplete — fix the above before the PR is merged." >&2
fi
exit $fail
