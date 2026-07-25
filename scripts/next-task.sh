#!/usr/bin/env bash
# next-task.sh — deterministic task picker for parallel agents
# Author: Timur Isaev
#
# Both agents share one GitHub account; the board's "Agent" field (claude |
# codex) records who actually holds a claimed task.
#
# A task is eligible to claim iff ALL of:
#   1. board status is "Todo"                        (Backlog = unshaped, not pickable)
#   2. it has no assignee                            (assignee = the lock)
#   3. every native "blocked by" issue is closed     (dependency edges)
#   4. its area:* labels are disjoint from every     (area mutexes; On Hold
#      task that is In Progress or On Hold            still holds its locks)
#   5. it has an Estimate                            (shaping gate, see below)
#
# Usage:
#   scripts/next-task.sh                        # list eligible tasks, best first
#   scripts/next-task.sh --claim claude|codex   # claim the top eligible task
#   scripts/next-task.sh --claim claude 45      # claim a named task, same gates
#
# Claiming assigns the account, sets Agent, moves the card to In Progress, and
# comments the agent name.  Finish with scripts/finish-task.sh, which sets
# Actual and reconciles closure.
#
# Two gates are enforced here rather than left to documentation, because a rule
# that lives only in a document keeps being skipped (#44):
#
#   Estimate  A Todo task without one was never fully shaped.  The claim is
#             refused, naming the task and printing the exact command to set it.
#   WIP       A shared pool of WIP_LIMIT tasks In Progress across all agents.
#             This was one task per agent, which refused claims while slots sat
#             free; the way around it was to hand-roll the claim, and that is
#             precisely how the Agent field kept ending up empty.  A limit that
#             people route around does not limit anything.
#
# Naming an issue narrows which task is claimed.  It does not relax a gate: a
# named task passes the same five eligibility rules, and is refused with the
# reason when it does not.
set -euo pipefail

OWNER="cleverClosure"
REPO="Alloy"
PROJECT=1
WIP_LIMIT=4

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
  }
}')

issues=$(jq --argjson proj "$PROJECT" '
  [.data.repository.issues.nodes[]
    | (.projectItems.nodes | map(select(.project.number == $proj)) | .[0]) as $item
    | {
        number,
        title,
        assigned: ((.assignees.nodes | length) > 0),
        founder: (([.labels.nodes[].name] | index("founder")) != null),
        areas: [.labels.nodes[].name | select(startswith("area:"))],
        prio: (([.labels.nodes[].name | select(startswith("priority:"))] | sort | .[0]) // "priority:P9"),
        open_blockers: [.blockedBy.nodes[] | select(.state == "OPEN") | .number],
        status: (if $item == null then "OFF_BOARD" else ($item.status.name // "Backlog") end),
        agent: ($item.agent.name // ""),
        estimate: ($item.estimate.number // null),
        item_id: ($item.id // "")
      }
  ]' <<<"$data")

locked=$(jq '[.[] | select(.status == "In Progress" or .status == "On Hold") | .areas[]] | unique' <<<"$issues")

eligible=$(jq --argjson locked "$locked" '
  [.[] | select(
      .status == "Todo"
      and (.founder | not)
      and (.assigned | not)
      and (.open_blockers | length == 0)
      and ((.areas - $locked) == .areas)
    )]
  | sort_by(.prio, .number)' <<<"$issues")

echo "── In work (holding area locks) ──────────────────────"
jq -r '.[] | select(.status == "In Progress" or .status == "On Hold")
  | "  #\(.number) [\(.status)\(if .agent != "" then "/" + .agent else "" end)] \(.areas | join(",")) — \(.title)"' <<<"$issues"

echo "── Eligible now (best first) ─────────────────────────"
jq -r 'to_entries[] | "  \(.key + 1). #\(.value.number) \(.value.prio | sub("priority:"; "")) \(.value.areas | join(",")) — \(.value.title)"
  + (if .value.estimate == null then "\n       ⚠ no Estimate — shape it before claiming" else "  [\(.value.estimate)h]" end)' <<<"$eligible"

echo "── Waiting (open Todo, not eligible) ─────────────────"
jq -r --argjson locked "$locked" '.[]
  | select(.status == "Todo" and ((.assigned) or (.founder)
      or (.open_blockers | length > 0)
      or ((.areas - $locked) != .areas)))
  | "  #\(.number) — " +
    (if .assigned then "already claimed"
     elif .founder then "founder-only"
     elif (.open_blockers | length > 0) then "blocked by " + (.open_blockers | map("#\(.)") | join(", "))
     else "area lock held: " + ((.areas - (.areas - $locked)) | join(",")) end)' <<<"$issues"

jq -r '.[] | select(.status == "OFF_BOARD")
  | "  ⚠ #\(.number) is not on the board — add it: gh project item-add '"$PROJECT"' --owner '"$OWNER"' --url https://github.com/'"$OWNER/$REPO"'/issues/\(.number)"' <<<"$issues"

if [[ "${1:-}" == "--claim" ]]; then
  agent="${2:-}"
  want="${3:-}"
  want="${want#\#}"
  if [[ "$agent" != "claude" && "$agent" != "codex" ]]; then
    echo "Usage: scripts/next-task.sh --claim claude|codex [issue]" >&2
    exit 1
  fi
  if [[ -n "$want" && ! "$want" =~ ^[0-9]+$ ]]; then
    echo "Usage: scripts/next-task.sh --claim claude|codex [issue]  (issue must be a number)" >&2
    exit 1
  fi

  # WIP is a shared pool across agents rather than a per-agent allowance. Only
  # In Progress occupies a slot: On Hold keeps its area locks but is not work in
  # flight, so it does not consume one.
  wip=$(jq '[.[] | select(.status == "In Progress") | .number]' <<<"$issues")
  wip_n=$(jq -r 'length' <<<"$wip")
  if ((wip_n >= WIP_LIMIT)); then
    printf 'WIP limit: %d of %d slots in use (%s) — finish one or move it On Hold first.\n' \
      "$wip_n" "$WIP_LIMIT" "$(jq -r 'map("#\(.)") | join(", ")' <<<"$wip")" >&2
    exit 1
  fi

  if [[ -n "$want" ]]; then
    candidate=$(jq --argjson n "$want" 'map(select(.number == $n)) | .[0] // empty' <<<"$eligible")
    if [[ -z "$candidate" ]]; then
      echo "#$want is not eligible to claim:" >&2
      jq -r --argjson n "$want" --argjson locked "$locked" '
        (map(select(.number == $n)) | .[0]) as $t
        | if $t == null then "  no open issue #\($n) is on the board"
          elif $t.status != "Todo" then "  board status is \($t.status), not Todo"
          elif $t.founder then "  founder-only work is never agent-claimable"
          elif $t.assigned then "  already claimed — the assignee is the lock"
          elif ($t.open_blockers | length > 0) then
            "  blocked by " + ($t.open_blockers | map("#\(.)") | join(", "))
          elif (($t.areas - $locked) != $t.areas) then
            "  area lock held: " + (($t.areas - ($t.areas - $locked)) | join(","))
          else "  not eligible" end' <<<"$issues" >&2
      exit 1
    fi
  else
    candidate=$(jq '.[0] // empty' <<<"$eligible")
    if [[ -z "$candidate" ]]; then
      echo "Nothing eligible to claim." >&2
      exit 1
    fi
  fi

  top=$(jq -r '.number' <<<"$candidate")
  item_id=$(jq -r '.item_id' <<<"$candidate")
  estimate=$(jq -r 'if .estimate == null then "" else (.estimate | tostring) end' <<<"$candidate")

  fields=$(gh project field-list "$PROJECT" --owner "$OWNER" --format json)
  project_id=$(gh project view "$PROJECT" --owner "$OWNER" --format json | jq -r '.id')

  # Estimate is a shaping gate: it belongs on the item before the task leaves
  # Backlog. Refuse rather than quietly skip to the next candidate — skipping
  # would hide an unshaped task instead of getting it shaped.
  if [[ -z "$estimate" ]]; then
    estimate_field=$(jq -r '.fields[] | select(.name == "Estimate") | .id' <<<"$fields")
    cat >&2 <<EOF
Estimate missing: #$top has no Estimate, so it is not ready to be claimed.
Set it in hours on the board item, then claim again:

  gh project item-edit --id $item_id \\
    --project-id $project_id \\
    --field-id $estimate_field --number <hours>

Estimate is set during shaping, before a task moves Backlog -> Todo (TASKS.md).
EOF
    exit 1
  fi

  # set_option <field-name> <option-name> — write a single-select value on the item
  set_option() {
    local field_id option_id
    field_id=$(jq -r --arg f "$1" '.fields[] | select(.name == $f) | .id' <<<"$fields")
    option_id=$(jq -r --arg f "$1" --arg o "$2" '.fields[] | select(.name == $f) | .options[] | select(.name == $o) | .id' <<<"$fields")
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
  }

  gh issue edit "$top" --repo "$OWNER/$REPO" --add-assignee "@me" >/dev/null
  set_option "Status" "In Progress"
  set_option "Agent" "$agent"
  gh issue comment "$top" --repo "$OWNER/$REPO" --body "Claimed by \`$agent\`." >/dev/null

  echo "── Claimed ───────────────────────────────────────────"
  echo "  #$top assigned to $agent, moved to In Progress (Estimate ${estimate}h)"
  echo "  Slots:  $((wip_n + 1)) of $WIP_LIMIT in use"
  echo "  Branch: git checkout -b task/$top-<slug>"
  echo "  Finish: scripts/finish-task.sh $top <actual-hours>"
fi
