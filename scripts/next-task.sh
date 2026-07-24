#!/usr/bin/env bash
# next-task.sh — deterministic task picker for parallel agents
# Author: Tim Isaev
#
# A task is eligible to claim iff ALL of:
#   1. board status is "Todo"                        (Backlog = unshaped, not pickable)
#   2. it has no assignee                            (assignee = the lock)
#   3. every native "blocked by" issue is closed     (dependency edges)
#   4. its area:* labels are disjoint from every     (area mutexes; On Hold
#      task that is In Progress or On Hold            still holds its locks)
#
# Usage:
#   scripts/next-task.sh                  # list eligible tasks, best first
#   scripts/next-task.sh --claim [name]   # claim the top task: assign yourself,
#                                         #  move to In Progress, comment claimant
set -euo pipefail

OWNER="cleverClosure"
REPO="Alloy"
PROJECT=1

# shellcheck disable=SC2016 # $vars in the query are GraphQL variables, not shell
data=$(gh api graphql \
  -f owner="$OWNER" -f name="$REPO" \
  -f query='
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, states: OPEN) {
      nodes {
        number
        title
        assignees(first: 10) { nodes { login } }
        labels(first: 20) { nodes { name } }
        blockedBy(first: 50) { nodes { number state } }
        projectItems(first: 10) {
          nodes {
            id
            project { number }
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
          }
        }
      }
    }
  }
}')

issues=$(jq --argjson proj "$PROJECT" '
  [.data.repository.issues.nodes[]
    | (.projectItems.nodes | map(select(.project.number == $proj)) | .[0]) as $item
    | {
        number,
        title,
        assigned: ((.assignees.nodes | length) > 0),
        areas: [.labels.nodes[].name | select(startswith("area:"))],
        prio: (([.labels.nodes[].name | select(startswith("priority:"))] | sort | .[0]) // "priority:P9"),
        open_blockers: [.blockedBy.nodes[] | select(.state == "OPEN") | .number],
        status: (if $item == null then "OFF_BOARD" else ($item.fieldValueByName.name // "Backlog") end),
        item_id: ($item.id // "")
      }
  ]' <<<"$data")

locked=$(jq '[.[] | select(.status == "In Progress" or .status == "On Hold") | .areas[]] | unique' <<<"$issues")

eligible=$(jq --argjson locked "$locked" '
  [.[] | select(
      .status == "Todo"
      and (.assigned | not)
      and (.open_blockers | length == 0)
      and ((.areas - $locked) == .areas)
    )]
  | sort_by(.prio, .number)' <<<"$issues")

echo "── In work (holding area locks) ──────────────────────"
jq -r '.[] | select(.status == "In Progress" or .status == "On Hold")
  | "  #\(.number) [\(.status)] \(.areas | join(",")) — \(.title)"' <<<"$issues"

echo "── Eligible now (best first) ─────────────────────────"
jq -r 'to_entries[] | "  \(.key + 1). #\(.value.number) \(.value.prio | sub("priority:"; "")) \(.value.areas | join(",")) — \(.value.title)"' <<<"$eligible"

echo "── Waiting (open Todo, not eligible) ─────────────────"
jq -r --argjson locked "$locked" '.[]
  | select(.status == "Todo" and ((.assigned)
      or (.open_blockers | length > 0)
      or ((.areas - $locked) != .areas)))
  | "  #\(.number) — " +
    (if .assigned then "already claimed"
     elif (.open_blockers | length > 0) then "blocked by " + (.open_blockers | map("#\(.)") | join(", "))
     else "area lock held: " + ((.areas - (.areas - $locked)) | join(",")) end)' <<<"$issues"

jq -r '.[] | select(.status == "OFF_BOARD")
  | "  ⚠ #\(.number) is not on the board — add it: gh project item-add '"$PROJECT"' --owner '"$OWNER"' --url https://github.com/'"$OWNER/$REPO"'/issues/\(.number)"' <<<"$issues"

if [[ "${1:-}" == "--claim" ]]; then
  agent="${2:-agent}"
  top=$(jq -r '.[0] // empty | .number' <<<"$eligible")
  if [[ -z "$top" ]]; then
    echo "Nothing eligible to claim."
    exit 1
  fi
  item_id=$(jq -r '.[0].item_id' <<<"$eligible")

  fields=$(gh project field-list "$PROJECT" --owner "$OWNER" --format json)
  field_id=$(jq -r '.fields[] | select(.name == "Status") | .id' <<<"$fields")
  option_id=$(jq -r '.fields[] | select(.name == "Status") | .options[] | select(.name == "In Progress") | .id' <<<"$fields")
  project_id=$(gh project view "$PROJECT" --owner "$OWNER" --format json | jq -r '.id')

  gh issue edit "$top" --repo "$OWNER/$REPO" --add-assignee "@me" >/dev/null
  # shellcheck disable=SC2016 # $vars in the query are GraphQL variables, not shell
  gh api graphql \
    -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$field_id" -f optionId="$option_id" \
    -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
    value: { singleSelectOptionId: $optionId }
  }) { projectV2Item { id } }
}' >/dev/null
  gh issue comment "$top" --repo "$OWNER/$REPO" --body "Claimed by \`$agent\`." >/dev/null

  echo "── Claimed ───────────────────────────────────────────"
  echo "  #$top assigned, moved to In Progress (agent: $agent)"
  echo "  Branch: git checkout -b task/$top-<slug>"
fi
