#!/usr/bin/env bash
# gates-selftest.sh — prove the board gates actually refuse
# Author: Tim Isaev
#
# next-task.sh and finish-task.sh exist to refuse things. A gate that has only
# ever been seen to pass is indistinguishable from one that cannot fail, and the
# board audit behind #44 happened precisely because rules nobody exercised were
# quietly not running. So each case here builds a synthetic board, runs the real
# script against a stubbed `gh`, and requires the expected refusal.
#
# The stub is a PATH shim: it answers the handful of `gh` subcommands the two
# scripts use from fixture files, and appends every mutation to a log the cases
# assert on. Nothing here touches the real board.
#
# Usage: gates-selftest.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/alloy-gates-selftest.XXXXXX")
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
# Minimal `gh` for the board gates. Fixtures live in $FIXTURE; mutations are
# appended to $FIXTURE/mutations.log so cases can assert on side effects.
set -uo pipefail
args=("$@")
sub="${1:-} ${2:-}"

# Honour --jq the way real gh does. Without this the stub hands back raw JSON
# where the caller expects a scalar, and the difference shows up as a failure in
# the script under test rather than in the stub - which it did, once.
emit() { # file-or-'-'
  local expr="" prev="" a
  for a in "${args[@]}"; do
    [[ $prev == "--jq" ]] && expr=$a
    prev=$a
  done
  if [[ -n $expr ]]; then jq -r "$expr" "$1"; else cat "$1"; fi
}

case "$sub" in
  "api graphql")
    # The board read passes -f owner=...; every mutation passes -f projectId=...
    if printf '%s\n' "$@" | grep -q '^projectId='; then
      printf '%s\n' "$*" >>"$FIXTURE/mutations.log"
      echo '{"data":{}}'
    else
      emit "$FIXTURE/board.json"
    fi
    ;;
  "project field-list") emit "$FIXTURE/fields.json" ;;
  "project view") echo '{"id":"PVT_test"}' ;;
  "project item-list") emit "$FIXTURE/items.json" ;;
  "pr list") emit "$FIXTURE/prs.json" ;;
  "issue view") emit "$FIXTURE/issue.json" ;;
  "run list") emit "$FIXTURE/runs.json" ;;
  "issue edit" | "issue comment" | "issue close" | "pr ready" | "run rerun")
    printf '%s\n' "$*" >>"$FIXTURE/mutations.log"
    ;;
  *)
    echo "stub: unhandled: $*" >&2
    exit 90
    ;;
esac
STUB
chmod +x "$work/bin/gh"

cat >"$work/fields.json" <<'EOF'
{"fields":[
  {"name":"Status","id":"F_status","options":[{"name":"Todo","id":"o_todo"},{"name":"In Progress","id":"o_wip"},{"name":"Done","id":"o_done"}]},
  {"name":"Agent","id":"F_agent","options":[{"name":"claude","id":"o_claude"},{"name":"codex","id":"o_codex"}]},
  {"name":"Estimate","id":"F_estimate","options":[]},
  {"name":"Actual","id":"F_actual","options":[]}
]}
EOF

# board <name> <status> <estimate-or-null> [extra-in-progress-count]
# Emits the GraphQL shape next-task.sh consumes: one claimable task plus as many
# In Progress tasks as the case needs to fill the WIP pool.
make_board() { # dir status estimate wip_extra
  local dir=$1 status=$2 estimate=$3 extra=${4:-0} nodes="" i
  nodes=$(
    cat <<EOF
{"number":100,"title":"candidate","assignees":{"nodes":[]},
 "labels":{"nodes":[{"name":"area:tools"},{"name":"priority:P1"}]},
 "blockedBy":{"nodes":[]},
 "projectItems":{"nodes":[{"id":"ITEM_100","project":{"number":1},
   "status":{"name":"$status"},"agent":null,
   "estimate":$(if [[ $estimate == null ]]; then echo null; else echo "{\"number\":$estimate}"; fi)}]}}
EOF
  )
  for ((i = 0; i < extra; i++)); do
    nodes+=",
{\"number\":$((200 + i)),\"title\":\"busy $i\",\"assignees\":{\"nodes\":[{\"login\":\"x\"}]},
 \"labels\":{\"nodes\":[{\"name\":\"area:busy$i\"}]},
 \"blockedBy\":{\"nodes\":[]},
 \"projectItems\":{\"nodes\":[{\"id\":\"ITEM_$((200 + i))\",\"project\":{\"number\":1},
   \"status\":{\"name\":\"In Progress\"},\"agent\":{\"name\":\"codex\"},\"estimate\":{\"number\":1}}]}}"
  done
  mkdir -p "$dir"
  printf '{"data":{"repository":{"issues":{"nodes":[%s]}}}}\n' "$nodes" >"$dir/board.json"
  cp "$work/fields.json" "$dir/fields.json"
  : >"$dir/mutations.log"
}

# Runs the real script against a fixture board, setting `out` and `status`.
# Callers read those rather than $?, which cannot survive the assignment.
run_claim() { # fixture-dir args...
  local dir=$1
  shift
  out=$(FIXTURE="$dir" PATH="$work/bin:$PATH" "$here/next-task.sh" --claim "$@" 2>&1)
  status=$?
}

# ── 1. Estimate missing: the claim is refused and says how to set it ──────────
make_board "$work/c1" Todo null 0
run_claim "$work/c1" claude
if ((status == 0)); then
  fold "estimate-missing: claim succeeded on a task with no Estimate" "$out"
elif ! grep -q 'Estimate missing' <<<"$out"; then
  fold "estimate-missing: wrong refusal" "$out"
elif ! grep -q 'F_estimate' <<<"$out"; then
  fold "estimate-missing: refusal does not name the field to set" "$out"
elif grep -q 'ITEM_100' "$work/c1/mutations.log"; then
  fold "estimate-missing: refused but still wrote to the board" "$(cat "$work/c1/mutations.log")"
else
  pass estimate-missing
fi

# ── 2. WIP pool full: refused even though the task is otherwise perfect ───────
make_board "$work/c2" Todo 4 3
run_claim "$work/c2" claude
if ((status == 0)); then
  fold "wip-full: claim succeeded with the pool full" "$out"
elif ! grep -q 'WIP limit: 3 of 3' <<<"$out"; then
  fold "wip-full: wrong refusal" "$out"
else
  pass wip-full
fi

# ── 3. WIP counts In Progress only — On Hold keeps locks but frees a slot ─────
make_board "$work/c3" Todo 4 2
run_claim "$work/c3" claude
if ((status != 0)); then
  fold "wip-has-room: refused with a free slot" "$out"
elif ! grep -q 'Claimed' <<<"$out"; then
  fold "wip-has-room: did not claim" "$out"
elif ! grep -q 'o_claude' "$work/c3/mutations.log"; then
  fold "wip-has-room: claimed without setting the Agent field" "$(cat "$work/c3/mutations.log")"
else
  pass wip-has-room
fi

# ── 4. A named task that is not eligible is refused, with the reason ──────────
make_board "$work/c4" Backlog 4 0
run_claim "$work/c4" claude 100
if ((status == 0)); then
  fold "named-ineligible: claimed a Backlog task" "$out"
elif ! grep -q 'board status is Backlog' <<<"$out"; then
  fold "named-ineligible: did not explain why" "$out"
else
  pass named-ineligible
fi

# ── 5. Naming a task does not bypass the Estimate gate ────────────────────────
make_board "$work/c5" Todo null 0
run_claim "$work/c5" claude 100
if ((status == 0)); then
  fold "named-skips-no-gate: naming a task bypassed the Estimate gate" "$out"
elif ! grep -q 'Estimate missing' <<<"$out"; then
  fold "named-skips-no-gate: wrong refusal" "$out"
else
  pass named-skips-no-gate
fi

# ── finish-task.sh ────────────────────────────────────────────────────────────
make_finish() { # dir issue-state pr-state pr-body card-status
  local dir=$1
  mkdir -p "$dir"
  cp "$work/fields.json" "$dir/fields.json"
  : >"$dir/mutations.log"
  cat >"$dir/board.json" <<EOF
{"data":{"repository":{"issue":{"state":"$2","title":"t","projectItems":{"nodes":[
  {"id":"ITEM_100","project":{"number":1,"id":"PVT_test"},
   "status":{"name":"$5"},"agent":{"name":"claude"},"estimate":{"number":6}}]}}}}}
EOF
  cat >"$dir/prs.json" <<EOF
[{"number":900,"state":"$3","isDraft":false,"body":$4,"title":"a title",
  "headRefName":"task/100-x","headRefOid":"abc1234def","url":"u",
  "closingIssuesReferences":[{"number":100}]}]
EOF
  echo '[]' >"$dir/runs.json"
  printf '{"state":"%s"}\n' "$2" >"$dir/issue.json"
  printf '{"items":[{"content":{"number":100},"status":"%s"}]}\n' "$5" >"$dir/items.json"
}

run_finish() {
  local dir=$1
  shift
  out=$(FIXTURE="$dir" PATH="$work/bin:$PATH" "$here/finish-task.sh" "$@" 2>&1)
  status=$?
}

# 6. Closing keyword absent from the body: refused, and --ready does not fire.
make_finish "$work/f1" OPEN OPEN '"no keyword here"' "In Progress"
run_finish "$work/f1" 100 2 --ready
if ((status == 0)); then
  fold "keyword-missing: finish reported ok without a closing keyword" "$out"
elif ! grep -q 'no closing keyword' <<<"$out"; then
  fold "keyword-missing: wrong failure" "$out"
elif grep -q 'pr ready' "$work/f1/mutations.log"; then
  fold "keyword-missing: marked the PR ready anyway" "$(cat "$work/f1/mutations.log")"
elif ! grep -q 'F_actual' "$work/f1/mutations.log"; then
  fold "keyword-missing: did not record Actual" "$(cat "$work/f1/mutations.log")"
else
  pass keyword-missing
fi

# 7. Keyword in the title only is not enough — GitHub reads the body.
make_finish "$work/f2" OPEN OPEN '"body without it"' "In Progress"
sed -i '' 's/"title":"a title"/"title":"work (closes #100)"/' "$work/f2/prs.json"
echo '[{"databaseId":776,"status":"completed"}]' >"$work/f2/runs.json"
run_finish "$work/f2" 100 2
if ((status == 0)); then
  fold "keyword-title-only: accepted a title-only closing keyword" "$out"
elif ! grep -q 'title but not the body' <<<"$out"; then
  fold "keyword-title-only: wrong failure" "$out"
elif grep -q 'run rerun' "$work/f2/mutations.log"; then
  # With no closing reference the board gate sees "not a task PR" and merges it
  # unchecked, so re-running CI here would wave it straight through.
  fold "keyword-title-only: re-ran CI for a PR that closes nothing" "$(cat "$work/f2/mutations.log")"
else
  pass keyword-title-only
fi

# 8. Merged but the issue never closed: reconciled, not trusted.
make_finish "$work/f3" OPEN MERGED '"Fixes #100"' "In Progress"
run_finish "$work/f3" 100 2
if ((status != 0)); then
  fold "reconcile: failed on a well-formed finish" "$out"
elif ! grep -q 'issue close 100' "$work/f3/mutations.log"; then
  fold "reconcile: merged PR but the open issue was left open" "$(cat "$work/f3/mutations.log")"
elif ! grep -q 'o_done' "$work/f3/mutations.log"; then
  fold "reconcile: issue closed but the card was not moved to Done" "$(cat "$work/f3/mutations.log")"
else
  pass reconcile
fi

# 9. Already closed and Done: nothing is touched a second time.
make_finish "$work/f4" CLOSED MERGED '"Fixes #100"' "Done"
run_finish "$work/f4" 100 2
if ((status != 0)); then
  fold "reconcile-idempotent: failed on an already-finished task" "$out"
elif grep -q 'issue close' "$work/f4/mutations.log"; then
  fold "reconcile-idempotent: re-closed an already closed issue" "$(cat "$work/f4/mutations.log")"
else
  pass reconcile-idempotent
fi

# 10. Not merged yet: closure is left alone, because an open issue is correct.
make_finish "$work/f5" OPEN OPEN '"Fixes #100"' "In Progress"
run_finish "$work/f5" 100 2
if ((status != 0)); then
  fold "premature: failed on an unmerged but well-formed PR" "$out"
elif grep -q 'issue close' "$work/f5/mutations.log"; then
  fold "premature: closed the issue before the PR merged" "$(cat "$work/f5/mutations.log")"
elif ! grep -q 'not merged yet' <<<"$out"; then
  fold "premature: did not say why closure was skipped" "$out"
else
  pass premature
fi

# 11. A ready PR the board gate may be holding: recording Actual re-runs its CI,
# because a board edit fires no event and auto-merge only wakes on CI.
make_finish "$work/f6" OPEN OPEN '"Fixes #100"' "In Progress"
echo '[{"databaseId":777,"status":"completed"}]' >"$work/f6/runs.json"
run_finish "$work/f6" 100 2
if ((status != 0)); then
  fold "rerun: failed on a well-formed finish" "$out"
elif ! grep -q 'run rerun 777' "$work/f6/mutations.log"; then
  fold "rerun: Actual recorded but the held PR was never re-evaluated" "$(cat "$work/f6/mutations.log")"
else
  pass rerun
fi

# 12. CI still running: it will wake auto-merge itself, so no re-run is queued.
make_finish "$work/f7" OPEN OPEN '"Fixes #100"' "In Progress"
echo '[{"databaseId":778,"status":"in_progress"}]' >"$work/f7/runs.json"
run_finish "$work/f7" 100 2
if ((status != 0)); then
  fold "rerun-in-flight: failed on a well-formed finish" "$out"
elif grep -q 'run rerun' "$work/f7/mutations.log"; then
  fold "rerun-in-flight: re-ran CI that had not finished" "$(cat "$work/f7/mutations.log")"
else
  pass rerun-in-flight
fi

# 13. A draft marked ready: ready_for_review starts CI, so no re-run either.
make_finish "$work/f8" OPEN OPEN '"Fixes #100"' "In Progress"
sed -i '' 's/"isDraft":false/"isDraft":true/' "$work/f8/prs.json"
echo '[{"databaseId":779,"status":"completed"}]' >"$work/f8/runs.json"
run_finish "$work/f8" 100 2 --ready
if ((status != 0)); then
  fold "ready-no-rerun: failed on a well-formed finish" "$out"
elif ! grep -q 'pr ready 900' "$work/f8/mutations.log"; then
  fold "ready-no-rerun: draft was not marked ready" "$(cat "$work/f8/mutations.log")"
elif grep -q 'run rerun' "$work/f8/mutations.log"; then
  fold "ready-no-rerun: re-ran CI on top of the ready_for_review run" "$(cat "$work/f8/mutations.log")"
else
  pass ready-no-rerun
fi

echo
if ((fail == 0)); then
  echo "GATES-SELFTEST: pass — every gate refuses its case, and the happy paths still work"
else
  echo "GATES-SELFTEST: FAIL — a gate does not enforce what it claims." >&2
fi
exit $fail
