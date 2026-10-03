#!/usr/bin/env bash
# Prove the auto-merge board gate refuses, and stops refusing once fixed.
# Author: Tim Isaev
#
# merge-gate.sh --selftest covers the decisions; this covers the plumbing around
# them, because the acceptance criteria for the gate are all end-to-end: hold a
# PR with one comment, do not repeat the comment while it stays held, merge the
# identical PR once the field is set, and leave a PR with no closing reference
# completely alone.
#
# Same approach as scripts/gates-selftest.sh: a PATH shim answers the handful of
# `gh` calls the gate makes from fixture files, and records every mutation so a
# case can assert on what the gate did rather than only on what it printed.
# Comment state is mutable, so a repeat poll sees the comment the previous poll
# left - which is the only way to test that it is not posted twice.
#
# Usage: merge-gate-selftest.sh
#
# shellcheck disable=SC2016
# The assertions match Markdown backticks in the gate's comment body, so
# `Estimate` and `Actual` are literal text and must not expand.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/alloy-merge-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT

fail=0
pass() { printf 'ok: %s\n' "$1"; }
fold() {
  printf 'FAIL: %s\n' "$1" >&2
  shift
  printf '%s\n' "$@" | sed 's/^/        /' >&2
  fail=1
}

# ── the gh stub ───────────────────────────────────────────────────────────────
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh` for the merge gate. Fixtures live in $FIXTURE; comments.json is
# read-write so repeat polls observe earlier comments; mutations are appended to
# $FIXTURE/mutations.log.
set -uo pipefail
args=("$@")

jq_expr() {
  local prev="" a
  for a in "${args[@]}"; do
    [[ $prev == "--jq" ]] && { printf '%s' "$a"; return; }
    prev=$a
  done
}

emit() { # json-text
  local expr
  expr=$(jq_expr)
  if [[ -n $expr ]]; then jq -r "$expr" <<<"$1"; else printf '%s\n' "$1"; fi
}

case "${1:-} ${2:-}" in
  "pr view")
    if [[ -e $FIXTURE/pr.fail ]]; then
      echo 'HTTP 502: Bad Gateway (https://api.github.com/graphql)' >&2
      exit 1
    fi
    emit "$(cat "$FIXTURE/pr.json")"
    ;;
  "api graphql")
    # The board read runs with GH_TOKEN set to PROJECT_TOKEN. A token that
    # cannot see the project gets GitHub's NOT_FOUND shape and a non-zero exit,
    # exactly as the real CLI behaves on a GraphQL error.
    if [[ ${GH_TOKEN-} != "project-token" ]]; then
      echo '{"data":{"repository":null},"errors":[{"type":"NOT_FOUND"}]}'
      exit 1
    fi
    # Answer for the issue actually asked about. A stub that serves one board
    # to every question cannot tell a gate that checks every closed issue from
    # one that checks only the first.
    issue=""
    for a in "${args[@]}"; do
      [[ $a == number=* ]] && issue=${a#number=}
    done
    if [[ -e $FIXTURE/board-$issue.json ]]; then
      cat "$FIXTURE/board-$issue.json"
    else
      cat "$FIXTURE/board.json"
    fi
    ;;
  "issue comment")
    body=""
    prev=""
    for a in "${args[@]}"; do
      [[ $prev == "--body" ]] && body=$a
      prev=$a
    done
    jq --arg b "$body" \
      '. + [{id: (length + 1000), body: $b, user: {login: "github-actions[bot]"}}]' \
      "$FIXTURE/comments.json" >"$FIXTURE/comments.tmp" || {
      echo "stub: failed to record the comment" >&2
      exit 92
    }
    mv "$FIXTURE/comments.tmp" "$FIXTURE/comments.json"
    echo "issue comment" >>"$FIXTURE/mutations.log"
    ;;
  "api -X")
    # PATCH of an existing comment. The id comes from the endpoint argument, not
    # from a fixed position: $3 is the verb, and reading it as the id silently
    # corrupts the fixture instead of failing, which it did once.
    id=""
    body=""
    prev=""
    for a in "${args[@]}"; do
      [[ $a == repos/*/issues/comments/* ]] && id=${a##*/}
      [[ $prev == "-f" && $a == body=* ]] && body=${a#body=}
      prev=$a
    done
    if [[ ! $id =~ ^[0-9]+$ ]]; then
      echo "stub: could not find a comment id in: $*" >&2
      exit 91
    fi
    if [[ $3 == DELETE ]]; then
      jq --argjson id "$id" 'map(select(.id != $id))' \
        "$FIXTURE/comments.json" >"$FIXTURE/comments.tmp" || {
        echo "stub: failed to delete comment $id" >&2
        exit 92
      }
      mv "$FIXTURE/comments.tmp" "$FIXTURE/comments.json"
      echo "comment delete $id" >>"$FIXTURE/mutations.log"
      exit 0
    fi
    jq --argjson id "$id" --arg b "$body" \
      'map(if .id == $id then .body = $b else . end)' \
      "$FIXTURE/comments.json" >"$FIXTURE/comments.tmp" || {
      echo "stub: failed to patch comment $id" >&2
      exit 92
    }
    mv "$FIXTURE/comments.tmp" "$FIXTURE/comments.json"
    echo "comment patch $id" >>"$FIXTURE/mutations.log"
    ;;
  "api repos"*)
    target=$2
    if [[ $target == *"/issues/comments/"* ]]; then
      id=${target##*/}
      emit "$(jq --argjson id "$id" 'map(select(.id == $id)) | .[0]' "$FIXTURE/comments.json")"
    else
      # --paginate --slurp wraps the pages in an outer array.
      emit "$(jq -s '.' "$FIXTURE/comments.json")"
    fi
    ;;
  *)
    echo "stub: unhandled: $*" >&2
    exit 90
    ;;
esac
STUB
chmod +x "$work/bin/gh"

# ── fixtures ──────────────────────────────────────────────────────────────────

board() { # estimate-json actual-json -> a board answer for one issue
  cat <<EOF
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
  {"project":{"number":1},"estimate":$1,"actual":$2}]}}}}}
EOF
}

make_case() { # dir "issue ..." estimate-json actual-json
  local dir=$1
  mkdir -p "$dir"
  : >"$dir/mutations.log"
  echo '[]' >"$dir/comments.json"
  # Closing references carry their repository, as the real API returns them.
  jq -n --arg ns "$2" '{closingIssuesReferences: ($ns | split(" ") | map(select(. != ""))
    | map({number: tonumber, repository: {name: "Alloy", owner: {login: "cleverClosure"}}}))}' \
    >"$dir/pr.json"
  board "$3" "$4" >"$dir/board.json"
}

path_prefix=""
run_gate() { # [project-token]
  out=$(
    FIXTURE="$dir_under_test" \
      PATH="$path_prefix$work/bin:$PATH" \
      NUMBER=900 REPOSITORY="cleverClosure/Alloy" CI_RUN_ID=4242 \
      GH_TOKEN="actions-token" PROJECT_TOKEN="${1-project-token}" \
      bash "$here/merge-gate.sh" 2>&1
  )
  status=$?
}

comment_count() { jq 'length' "$dir_under_test/comments.json"; }
comment_body() { jq -r '.[0].body // ""' "$dir_under_test/comments.json"; }

# ── 1. No closing reference: a docs PR merges exactly as before ───────────────
dir_under_test="$work/c1"
make_case "$dir_under_test" '' 'null' 'null'
run_gate
if ((status != 0)); then
  fold "no-reference: held a PR that closes no issue" "$out"
elif (($(comment_count) != 0)); then
  fold "no-reference: commented on a non-task PR" "$(comment_body)"
else
  pass no-reference
fi

# ── 2. Actual empty: held, with exactly one comment naming the field ──────────
dir_under_test="$work/c2"
make_case "$dir_under_test" '57' '{"number":3}' 'null'
run_gate
if ((status == 0)); then
  fold "actual-missing: merged a PR whose issue has no Actual" "$out"
elif (($(comment_count) != 1)); then
  fold "actual-missing: expected exactly one comment" "$(comment_count) posted"
elif [[ $(comment_body) != *'`Actual`'* ]]; then
  fold "actual-missing: comment does not name the missing field" "$(comment_body)"
elif [[ $(comment_body) != *'finish-task.sh 57'* ]]; then
  fold "actual-missing: comment does not point at the finish helper" "$(comment_body)"
elif [[ $(comment_body) == *'`Estimate`'* ]]; then
  fold "actual-missing: named a field that is actually set" "$(comment_body)"
else
  pass actual-missing
fi

# ── 3. Polled again while still unfixed: still held, still one comment ────────
run_gate
if ((status == 0)); then
  fold "no-repeat: merged on the second poll" "$out"
elif (($(comment_count) != 1)); then
  fold "no-repeat: commented again on the next poll" "$(comment_count) comments"
elif ! grep -q 'comment unchanged' <<<"$out"; then
  fold "no-repeat: did not report the comment as already present" "$out"
else
  pass no-repeat
fi

# ── 4. Actual set: the identical PR merges on the next run ────────────────────
cat >"$dir_under_test/board.json" <<'EOF'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
  {"project":{"number":1},"estimate":{"number":3},"actual":{"number":4}}]}}}}}
EOF
run_gate
if ((status != 0)); then
  fold "unblocks: still held after Actual was recorded" "$out"
elif (($(comment_count) != 0)); then
  fold "unblocks: left a hold comment on a PR it is releasing" "$(comment_body)"
elif ! grep -q 'comment delete' "$dir_under_test/mutations.log"; then
  fold "unblocks: did not remove the stale hold" "$(cat "$dir_under_test/mutations.log")"
else
  pass unblocks
fi

# ── 5. Estimate empty is caught too, and the comment is edited, not repeated ──
dir_under_test="$work/c5"
make_case "$dir_under_test" '57' 'null' 'null'
run_gate
first_body=$(comment_body)
cat >"$dir_under_test/board.json" <<'EOF'
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
  {"project":{"number":1},"estimate":{"number":3},"actual":null}]}}}}}
EOF
run_gate
if ((status == 0)); then
  fold "reason-changes: merged with Actual still empty" "$out"
elif [[ $first_body != *'`Estimate`'* ]]; then
  fold "reason-changes: first comment did not name Estimate" "$first_body"
elif (($(comment_count) != 1)); then
  fold "reason-changes: posted a second comment instead of editing" "$(comment_count)"
elif [[ $(comment_body) == *'`Estimate`'* ]]; then
  fold "reason-changes: stale comment still names the field that was set" "$(comment_body)"
elif ! grep -q 'comment patch' "$dir_under_test/mutations.log"; then
  fold "reason-changes: did not edit the existing comment" "$(cat "$dir_under_test/mutations.log")"
else
  pass reason-changes
fi

# ── 6. No PROJECT_TOKEN: held, not waved through ──────────────────────────────
dir_under_test="$work/c6"
make_case "$dir_under_test" '57' '{"number":3}' '{"number":4}'
run_gate ""
if ((status == 0)); then
  fold "no-token: merged without being able to read the board" "$out"
elif [[ $(comment_body) != *'`PROJECT_TOKEN` secret is not set'* ]]; then
  fold "no-token: comment does not say the secret is missing" "$(comment_body)"
else
  pass no-token
fi

# ── 7. Token present but rejected by the board: held ──────────────────────────
dir_under_test="$work/c7"
make_case "$dir_under_test" '57' '{"number":3}' '{"number":4}'
run_gate "expired-token"
if ((status == 0)); then
  fold "board-unreadable: merged on an unreadable board" "$out"
elif [[ $(comment_body) != *'could not be read'* ]]; then
  fold "board-unreadable: comment does not explain the fault" "$(comment_body)"
else
  pass board-unreadable
fi

# ── 8. Issue is not on the board at all: held ─────────────────────────────────
dir_under_test="$work/c8"
make_case "$dir_under_test" '57' '{"number":3}' '{"number":4}'
echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' \
  >"$dir_under_test/board.json"
run_gate
if ((status == 0)); then
  fold "off-board: merged an issue that is not on the board" "$out"
else
  pass off-board
fi

# ── 9. Several closed issues: a bad item that is not the first still holds ────
# The first issue is complete, so a gate that only checks the first one merges.
dir_under_test="$work/c9"
make_case "$dir_under_test" '57 58' '{"number":3}' '{"number":4}'
board '{"number":5}' 'null' >"$dir_under_test/board-58.json"
run_gate
if ((status == 0)); then
  fold "multi-issue: merged though the second closed issue lacks Actual" "$out"
elif [[ $(comment_body) != *'#58 `Actual`'* ]]; then
  fold "multi-issue: comment does not name the issue that is short" "$(comment_body)"
elif [[ $(comment_body) != *'finish-task.sh 58'* || $(comment_body) == *'finish-task.sh 57'* ]]; then
  fold "multi-issue: helper points at the wrong issue" "$(comment_body)"
else
  pass multi-issue
fi

# ── 10. Estimate empty only: the helper is not offered, the board is ──────────
# finish-task.sh cannot set Estimate; offering it would loop forever.
dir_under_test="$work/c10"
make_case "$dir_under_test" '76' 'null' '{"number":0}'
run_gate
if ((status == 0)); then
  fold "estimate-only: merged with Estimate empty" "$out"
elif [[ $(comment_body) == *'finish-task.sh'* ]]; then
  fold "estimate-only: offered a helper that cannot set Estimate" "$(comment_body)"
elif [[ $(comment_body) != *'project board'* || $(comment_body) != *'gh run rerun 4242'* ]]; then
  fold "estimate-only: comment does not say how to clear the hold" "$(comment_body)"
else
  pass estimate-only
fi

# ── 11. The field check itself dies: held, not read as "nothing missing" ──────
# A jq that is killed mid-check prints nothing. Through a process substitution
# that silence read as a complete item and merged a PR with both fields empty.
real_jq=$(command -v jq)
mkdir -p "$work/faultbin"
cat >"$work/faultbin/jq" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [[ \$a == *'select(.value == null)'* ]] && exit 137
done
exec "$real_jq" "\$@"
EOF
chmod +x "$work/faultbin/jq"
dir_under_test="$work/c11"
make_case "$dir_under_test" '57' 'null' 'null'
path_prefix="$work/faultbin:"
run_gate
path_prefix=""
if ((status == 0)); then
  fold "field-check-dies: merged when the field check could not run" "$out"
elif [[ $(comment_body) != *'could not be read'* ]]; then
  fold "field-check-dies: hold does not say the board was unreadable" "$(comment_body)"
else
  pass field-check-dies
fi

# ── 12. Someone else's comment carrying the marker is never touched ───────────
dir_under_test="$work/c12"
make_case "$dir_under_test" '57' '{"number":3}' '{"number":4}'
quoted='{"id":1,"body":"> <!-- auto-merge:board-fields -->\n> held\n\nOn it.","user":{"login":"cleverClosure"}}'
echo "[$quoted]" >"$dir_under_test/comments.json"
run_gate
allowed_status=$status
allowed_log=$(cat "$dir_under_test/mutations.log")
board '{"number":3}' 'null' >"$dir_under_test/board.json"
run_gate
human=$(jq -c '.[] | select(.id == 1)' "$dir_under_test/comments.json")
if ((allowed_status != 0)); then
  fold "foreign-marker: held a complete PR" "$out"
elif [[ -n $allowed_log ]]; then
  fold "foreign-marker: touched a comment it did not write" "$allowed_log"
elif [[ $human != "$quoted" ]]; then
  fold "foreign-marker: a person's comment was edited or deleted" "${human:-<deleted>}"
elif (($(comment_count) != 2)); then
  fold "foreign-marker: expected the gate's own comment beside the person's" "$(comment_count)"
else
  pass foreign-marker
fi

# ── 13. Closing an issue in another repository: held, not checked here ────────
# Local #5 is complete, so a gate that looked up the wrong #5 would merge.
dir_under_test="$work/c13"
make_case "$dir_under_test" '' '{"number":3}' '{"number":4}'
echo '{"closingIssuesReferences":[{"number":5,"repository":{"name":"tools","owner":{"login":"someone"}}}]}' \
  >"$dir_under_test/pr.json"
run_gate
if ((status == 0)); then
  fold "cross-repo: merged on an issue the gate cannot check" "$out"
elif [[ $(comment_body) != *'someone/tools#5'* ]]; then
  fold "cross-repo: comment does not name the outside issue" "$(comment_body)"
else
  pass cross-repo
fi

# ── 14. The closing reference cannot be resolved: held, not read as "none" ────
# An empty answer means "not a task PR"; an error must never be mistaken for it.
dir_under_test="$work/c14"
make_case "$dir_under_test" '57' 'null' 'null'
: >"$dir_under_test/pr.fail"
run_gate
if ((status == 0)); then
  fold "pr-unreadable: merged when the closing reference could not be read" "$out"
else
  pass pr-unreadable
fi

echo
if ((fail == 0)); then
  echo "MERGE-GATE-SELFTEST: pass — the gate refuses, explains once, and releases"
else
  echo "MERGE-GATE-SELFTEST: FAIL — the merge gate does not enforce what it claims." >&2
fi
exit $fail
