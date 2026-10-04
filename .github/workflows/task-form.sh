#!/usr/bin/env bash
# Turn the Task form's Area and Priority choices into labels.
# Author: Tim Isaev
#
# GitHub issue forms can make a field required, but they cannot make a label
# required, and a dropdown choice only ever arrives as text in the issue body.
# So the Task form asks for Area and Priority as dropdowns, and this script,
# run when an issue is opened, applies the matching labels and removes the two
# sections again. The body is left with the five headings every existing reader
# and tool already expects: PM summary, Goal, Depends on, Touches, Done when.
#
# It also writes "none" where an empty Depends on rendered as "_No response_",
# which is how that section has always read.
#
# Labels are applied before the body is rewritten. If a label does not exist the
# run fails with the choice still in the body, rather than losing it.
#
# A section counts as a dropdown only when it holds nothing but labels of its
# own kind, so an issue that merely has a heading called "Area" is left alone.
set -euo pipefail

# Populated by the workflow; the defaults keep --selftest offline.
NUMBER=${NUMBER-}
REPOSITORY=${REPOSITORY-}
GH_TOKEN=${GH_TOKEN-}

# ── pure logic ────────────────────────────────────────────────────────────────

# shape <mode> reads an issue body on stdin.
#   labels  the labels chosen in the form, one per line
#   body    the body with the form-only sections removed
#   plain   the body unchanged, normalized the same way, for comparison
shape() {
  awk -v mode="$1" '
    # A held section is decided once it is complete: a dropdown is dropped and
    # yields its labels, anything else is put back exactly as it was.
    function flush(    i, j, n, parts, value, dropdown, found, nfound) {
      if (held == 0) return
      dropdown = 1
      nfound = 0
      for (i = 2; i <= held; i++) {
        if (hold[i] == "" || hold[i] == "_No response_") continue
        n = split(hold[i], parts, ",")
        for (j = 1; j <= n; j++) {
          value = parts[j]
          gsub(/^[ \t]+|[ \t]+$/, "", value)
          if (value ~ ("^" kind ":[A-Za-z0-9-]+$")) found[++nfound] = value
          else dropdown = 0
        }
      }
      if (dropdown && mode == "labels")
        for (i = 1; i <= nfound; i++) print found[i]
      if (!dropdown && mode == "body")
        for (i = 1; i <= held; i++) out[++count] = hold[i]
      held = 0
    }

    { sub(/\r$/, "") }

    /^### / {
      flush()
      section = substr($0, 5)
      sub(/[ \t]+$/, "", section)
      kind = ""
      if (mode != "plain" && section == "Area") kind = "area"
      if (mode != "plain" && section == "Priority") kind = "priority"
    }

    kind != "" { hold[++held] = $0; next }

    mode != "labels" {
      if (mode == "body" && section == "Depends on" && $0 == "_No response_")
        $0 = "none"
      out[++count] = $0
    }

    END {
      flush()
      while (count > 0 && out[count] == "") count--
      for (i = 1; i <= count; i++) print out[i]
    }'
}

# ── self-test ─────────────────────────────────────────────────────────────────

run_selftest() {
  local failures=0 cases=0 here form expected got body

  check() { # name mode expected body
    local name=$1 mode=$2 expected=$3 body=$4 got
    cases=$((cases + 1))
    got=$(shape "$mode" <<<"$body")
    if [[ $got != "$expected" ]]; then
      printf 'FAIL %s (%s):\n--- expected\n%s\n--- got\n%s\n' "$name" "$mode" "$expected" "$got" >&2
      failures=$((failures + 1))
    fi
  }

  # Exactly what the form renders: a blank line after every heading, the
  # dropdowns last, several areas joined by ", ".
  form='### PM summary

Why it matters.

### Goal

The outcome.

### Depends on

_No response_

### Touches

.github/ISSUE_TEMPLATE/

### Done when

It works.

### Area

area:ci, area:third-party

### Priority

priority:P1'
  expected='### PM summary

Why it matters.

### Goal

The outcome.

### Depends on

none

### Touches

.github/ISSUE_TEMPLATE/

### Done when

It works.'
  check form labels 'area:ci
area:third-party
priority:P1' "$form"
  check form body "$expected" "$form"

  # Running again changes nothing: the workflow also fires on edits.
  check idempotent labels '' "$expected"
  check idempotent body "$expected" "$expected"
  check idempotent plain "$expected" "$expected"

  # Windows line endings, as a browser may submit them.
  check crlf labels 'area:gfx
priority:P0' $'### Goal\r\n\r\nx\r\n\r\n### Area\r\n\r\narea:gfx\r\n\r\n### Priority\r\n\r\npriority:P0\r\n'
  check crlf body $'### Goal\n\nx' $'### Goal\r\n\r\nx\r\n\r\n### Area\r\n\r\narea:gfx\r\n\r\n### Priority\r\n\r\npriority:P0\r\n'

  # A heading that happens to be called Area, holding prose: not a dropdown.
  body='### Goal

x

### Area

The area under the curve.'
  check prose-heading labels '' "$body"
  check prose-heading body "$body" "$body"

  # A label of the wrong kind is not a dropdown choice either. Accepting it
  # would let the Area field hand out a priority.
  body='### Area

priority:P0'
  check wrong-kind labels '' "$body"
  check wrong-kind body "$body" "$body"

  # An issue written by hand or through the API has no form sections at all.
  body='### PM summary
Text.

### Depends on
#57 — the gate'
  check api-body labels '' "$body"
  check api-body body "$body" "$body"

  # The form itself. Its headings must render in the order tooling expects,
  # every option must be something shape() accepts as a label of that field,
  # and only Depends on may be left empty.
  here=$(cd "$(dirname "$0")" && pwd)
  form="$here/../ISSUE_TEMPLATE/task.yml"
  cases=$((cases + 3))
  got=$(sed -n 's/^      label: //p' "$form" | paste -sd'|' -)
  if [[ $got != 'PM summary|Goal|Depends on|Touches|Done when|Area|Priority' ]]; then
    printf 'FAIL form-headings: %s\n' "$got" >&2
    failures=$((failures + 1))
  fi
  got=$(awk '
    /^      label: / { field = substr($0, 14) }
    /^        - / {
      option = substr($0, 11)
      kind = (field == "Area") ? "area" : "priority"
      if (option !~ ("^" kind ":[A-Za-z0-9-]+$")) print field ": " option
    }' "$form")
  if [[ -n $got ]]; then
    printf 'FAIL form-options: not usable as labels:\n%s\n' "$got" >&2
    failures=$((failures + 1))
  fi
  got=$(awk '
    /^      label: / { field = substr($0, 14) }
    /^      required: / { print field "=" $2 }' "$form" | paste -sd' ' -)
  expected='PM summary=true Goal=true Depends on=false Touches=true Done when=true Area=true Priority=true'
  if [[ $got != "$expected" ]]; then
    printf 'FAIL form-required: %s\n' "$got" >&2
    failures=$((failures + 1))
  fi

  run_plumbing_selftest || failures=$((failures + 1))
  cases=$((cases + 1))

  if ((failures > 0)); then
    printf 'task-form self-test: %d of %d case(s) failed\n' "$failures" "$cases" >&2
    return 1
  fi
  printf 'task-form self-test: %d case(s) passed\n' "$cases"
}

# The order of the two writes is the one decision the plumbing makes, so it is
# tested against a gh stub: labels first, and no body rewrite if they fail.
run_plumbing_selftest() {
  local work log bad=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/alloy-task-form.XXXXXX")
  # shellcheck disable=SC2064 # expand now: $work is local to this function
  trap "rm -rf '$work'" RETURN

  mkdir -p "$work/bin"
  cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-} ${2:-}" in
  "issue view")
    jq -n --rawfile b "$FIXTURE/body.md" '{body: $b}' | jq -r '.body'
    ;;
  "issue edit")
    prev=""
    for a in "$@"; do
      if [[ $prev == --add-label ]]; then
        if [[ -e $FIXTURE/label-missing ]]; then
          echo "could not add label: '$a' not found" >&2
          exit 1
        fi
        echo "add-label $a" >>"$FIXTURE/log"
      fi
      if [[ $prev == --body-file ]]; then
        echo "body" >>"$FIXTURE/log"
        cat >"$FIXTURE/new-body.md"
      fi
      prev=$a
    done
    ;;
  *)
    echo "stub: unhandled: $*" >&2
    exit 90
    ;;
esac
STUB
  chmod +x "$work/bin/gh"

  run_main() { # fixture-dir
    FIXTURE=$1 PATH="$work/bin:$PATH" NUMBER=900 REPOSITORY=o/r GH_TOKEN=t \
      bash "$0" >"$1/out" 2>&1
  }

  mkdir -p "$work/ok" "$work/missing" "$work/plain"
  printf '### Goal\n\nx\n\n### Area\n\narea:ci\n\n### Priority\n\npriority:P2\n' |
    tee "$work/ok/body.md" >"$work/missing/body.md"
  printf '### Goal\nx\n' >"$work/plain/body.md"
  : >"$work/missing/label-missing"

  log=$(run_main "$work/ok" && cat "$work/ok/log")
  if [[ $log != $'add-label area:ci,priority:P2\nbody' ]]; then
    printf 'FAIL plumbing-order: expected labels then body, got:\n%s\n' "$log" >&2
    bad=1
  elif [[ $(cat "$work/ok/new-body.md") != $'### Goal\n\nx' ]]; then
    printf 'FAIL plumbing-body: %s\n' "$(cat "$work/ok/new-body.md")" >&2
    bad=1
  fi

  if run_main "$work/missing"; then
    printf 'FAIL plumbing-missing-label: succeeded with a label that does not exist\n' >&2
    bad=1
  elif [[ -e $work/missing/new-body.md ]]; then
    printf 'FAIL plumbing-missing-label: rewrote the body and lost the choice\n' >&2
    bad=1
  fi

  if ! run_main "$work/plain" || [[ -e $work/plain/log ]]; then
    printf 'FAIL plumbing-plain: touched an issue with no form sections\n' >&2
    bad=1
  fi

  return "$bad"
}

# ── entry point ───────────────────────────────────────────────────────────────

main() {
  local body labels shaped

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

  # Read the live issue rather than trusting a queued event's stale body. The
  # body is untrusted input: it is only ever parsed, never executed.
  body=$(gh issue view "$NUMBER" --repo "$REPOSITORY" --json body --jq .body)
  labels=$(shape labels <<<"$body")
  shaped=$(shape body <<<"$body")

  if [[ -n $labels ]]; then
    gh issue edit "$NUMBER" --repo "$REPOSITORY" \
      --add-label "$(paste -sd, - <<<"$labels")" >/dev/null
    printf 'Applied labels: %s\n' "${labels//$'\n'/, }"
  fi

  if [[ $shaped == "$(shape plain <<<"$body")" ]]; then
    printf 'No form-only sections in the body; left as written.\n'
    return
  fi
  gh issue edit "$NUMBER" --repo "$REPOSITORY" --body-file - <<<"$shaped" >/dev/null
  printf 'Removed the form-only sections from the body.\n'
}

main "$@"
