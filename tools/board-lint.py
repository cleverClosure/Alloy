#!/usr/bin/env python3
"""Board-invariant linter for the Alloy project board.

Author: Tim Isaev

The manual review on 25 July 2026 found five kinds of silent drift, every one
mechanically checkable and every one invisible for days. This sweeps them nightly
so drift surfaces within a day rather than at the next human audit.

Deliberately *not* checked: the number of In Progress items per agent. The
one-per-agent limit was relaxed on 25 July as inefficient, so flagging it would
report a rule that no longer exists — worse than not checking, because a linter
nobody trusts gets ignored wholesale.

Output is a findings list on stdout and a machine-readable summary on request.
Exit 0 whether or not findings exist; a board with drift is not a broken build,
it is a board that needs attention. The caller decides what to do about it.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone

QUERY = """
query($owner:String!,$num:Int!,$cursor:String){
 user(login:$owner){ projectV2(number:$num){
  items(first:100, after:$cursor){
   pageInfo{ hasNextPage endCursor }
   nodes{
    id
    content{ ... on Issue { number title state closedAt
                            labels(first:30){nodes{name}} } }
    fieldValues(first:30){ nodes{
      ... on ProjectV2ItemFieldSingleSelectValue { name field{ ... on ProjectV2SingleSelectField{name} } }
      ... on ProjectV2ItemFieldNumberValue { number field{ ... on ProjectV2Field{name} } }
      ... on ProjectV2ItemFieldTextValue { text field{ ... on ProjectV2Field{name} } }
    }}
   }
  }
 }}
}
"""

ACTIVE = ("In Progress", "On Hold")
EXTERNAL_LABEL = "hold:external"   # waiting on a third party
FOUNDER_LABEL = "founder"          # not agent-claimable per TASKS.md
STALE_DAYS = 7


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=False).stdout


def fetch_items(owner: str, num: int) -> list[dict]:
    items, cursor = [], None
    while True:
        cmd = ["api", "graphql", "-f", f"query={QUERY}", "-f", f"owner={owner}", "-F", f"num={num}"]
        if cursor:
            cmd += ["-f", f"cursor={cursor}"]
        raw = gh(*cmd)
        try:
            page = json.loads(raw)["data"]["user"]["projectV2"]["items"]
        except (KeyError, TypeError, json.JSONDecodeError):
            print(f"error: could not read project {owner}/{num}", file=sys.stderr)
            print(raw[:400], file=sys.stderr)
            sys.exit(2)
        items += page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            return items
        cursor = page["pageInfo"]["endCursor"]


def flatten(item: dict) -> dict | None:
    content = item.get("content") or {}
    if not content.get("number"):
        return None  # draft item, not an issue
    fields: dict[str, object] = {}
    for fv in item["fieldValues"]["nodes"]:
        if not fv:
            continue
        name = (fv.get("field") or {}).get("name")
        if name:
            fields[name] = fv.get("name", fv.get("number", fv.get("text")))
    return {
        "number": content["number"],
        "title": content.get("title", ""),
        "state": content.get("state"),
        "closedAt": content.get("closedAt"),
        "labels": [n["name"] for n in (content.get("labels") or {}).get("nodes", [])],
        "status": fields.get("Status"),
        "agent": fields.get("Agent"),
        "estimate": fields.get("Estimate"),
        "actual": fields.get("Actual"),
    }


def merged_branches() -> set[str]:
    """task/<n>-* branches already fully merged into origin/main."""
    out = gh("api", "repos/cleverClosure/Alloy/branches?per_page=100")
    try:
        names = [b["name"] for b in json.loads(out)]
    except (json.JSONDecodeError, TypeError):
        return set()
    merged = set()
    for name in names:
        if not name.startswith("task/"):
            continue
        r = subprocess.run(["git", "merge-base", "--is-ancestor", f"origin/{name}", "origin/main"],
                           capture_output=True, check=False)
        if r.returncode == 0:
            merged.add(name)
    return merged


def branch_age_days(branch: str) -> int | None:
    out = subprocess.run(["git", "log", "-1", "--format=%ct", f"origin/{branch}"],
                         capture_output=True, text=True, check=False).stdout.strip()
    if not out.isdigit():
        return None
    then = datetime.fromtimestamp(int(out), tz=timezone.utc)
    return (datetime.now(timezone.utc) - then).days


def branches_for(number: int, all_branches: list[str]) -> list[str]:
    return [b for b in all_branches if b.startswith(f"task/{number}-")]


def lint(items: list[dict], all_branches: list[str], merged: set[str]) -> list[tuple[str, str]]:
    findings: list[tuple[str, str]] = []
    cutoff = datetime.now(timezone.utc) - timedelta(days=STALE_DAYS)

    for it in items:
        n, status = it["number"], it["status"]
        labels = it["labels"]
        external = EXTERNAL_LABEL in labels
        founder = FOUNDER_LABEL in labels

        # A founder item legitimately has no agent - TASKS.md makes them
        # non-claimable. Flagging them would fire on every legal and sign-off
        # item forever, and a linter that cries wolf gets ignored wholesale,
        # taking its true findings with it.
        if status in ACTIVE and not it["agent"] and not founder:
            findings.append((f"#{n}", f"{status} but Agent is empty — nobody can tell who holds it"))

        # Work gated on a third party cannot be estimated honestly.
        if (it["state"] == "OPEN" and status and status != "Backlog"
                and it["estimate"] in (None, "") and not external):
            findings.append((f"#{n}", f"{status} with no Estimate"))

        if status == "Done" and it["actual"] in (None, ""):
            closed = it.get("closedAt")
            # Only recent closures: re-litigating months of history teaches
            # people to ignore the report.
            if closed and datetime.fromisoformat(closed.replace("Z", "+00:00")) >= cutoff:
                findings.append((f"#{n}", "Done in the last 7 days with no Actual recorded"))

        if status in ACTIVE and not external and not founder:
            mine = branches_for(n, all_branches)
            # A merged branch still holding a lock is drift regardless of status.
            stale = [b for b in mine if b in merged]
            if stale:
                findings.append((f"#{n}", f"{status} but {stale[0]} is fully merged — area lock likely stale"))
            # Absent branch is only a finding for On Hold. An In Progress item
            # may legitimately have been claimed minutes ago and not pushed.
            elif not mine and status == "On Hold":
                findings.append((f"#{n}", f"On Hold with no task/{n}-* branch — parked with nothing to resume"))

        # Area-lock age, using the branch's newest commit as a proxy for how
        # long the lock has been held; the board does not record when an item
        # entered its status, so this is an approximation and says so.
        if status in ACTIVE and not external:
            for b in branches_for(n, all_branches):
                age = branch_age_days(b)
                if age is not None and age > STALE_DAYS:
                    findings.append((f"#{n}", f"area lock held ~{age}d (branch {b} last touched then)"))
                    break

    return findings


def selftest() -> int:
    """Exercise every violation class against synthetic items.

    Seeding real violations on the live board would perturb it and prove the
    checks only once. This proves each class fires, and keeps proving it.
    """
    now = datetime.now(timezone.utc)
    recent = now.isoformat().replace("+00:00", "Z")
    old = (now - timedelta(days=60)).isoformat().replace("+00:00", "Z")

    def item(**kw):
        base = dict(number=0, title="t", state="OPEN", closedAt=None, labels=[],
                    status=None, agent=None, estimate=1, actual=1)
        base.update(kw)
        return base

    cases = [
        ("agent empty",        item(number=1, status="In Progress"),                      "Agent is empty"),
        ("estimate empty",     item(number=2, status="Todo", estimate=None),              "no Estimate"),
        ("actual empty",       item(number=3, status="Done", state="CLOSED",
                                    closedAt=recent, actual=None),                        "no Actual"),
        ("stale merged lock",  item(number=4, status="In Progress", agent="claude"),      "fully merged"),
        ("on hold, no branch", item(number=5, status="On Hold", agent="claude"),          "no task/5-* branch"),
    ]
    negatives = [
        ("founder w/o agent",  item(number=6, status="On Hold", labels=["founder"]),      "Agent is empty"),
        ("external w/o est",   item(number=7, status="Todo", estimate=None,
                                    labels=["hold:external"]),                            "no Estimate"),
        ("old Done ignored",   item(number=8, status="Done", state="CLOSED",
                                    closedAt=old, actual=None),                           "no Actual"),
    ]

    branches = ["task/4-merged"]
    merged = {"task/4-merged"}
    ok = True

    for label, it, expect in cases:
        found = lint([it], branches, merged)
        hit = any(expect in msg for _, msg in found)
        print(f"  {'PASS' if hit else 'FAIL'}  detects: {label}")
        ok &= hit

    for label, it, expect in negatives:
        found = lint([it], branches, merged)
        hit = any(expect in msg for _, msg in found)
        print(f"  {'PASS' if not hit else 'FAIL'}  exempts: {label}")
        ok &= not hit

    print("selftest:", "pass" if ok else "FAIL")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true",
                    help="prove each violation class fires, without touching the board")
    ap.add_argument("--owner", default="cleverClosure")
    ap.add_argument("--number", type=int, default=1)
    ap.add_argument("--json", action="store_true", help="emit findings as JSON")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    raw = fetch_items(args.owner, args.number)
    items = [x for x in (flatten(i) for i in raw) if x]

    subprocess.run(["git", "fetch", "-q", "origin"], check=False)
    out = gh("api", "repos/cleverClosure/Alloy/branches?per_page=100")
    try:
        all_branches = [b["name"] for b in json.loads(out)]
    except (json.JSONDecodeError, TypeError):
        all_branches = []

    findings = lint(items, all_branches, merged_branches())

    if args.json:
        print(json.dumps([{"item": a, "finding": b} for a, b in findings], indent=2))
    elif not findings:
        print(f"board clean — {len(items)} items checked")
    else:
        print(f"{len(findings)} finding(s) across {len(items)} items\n")
        for ref, msg in findings:
            print(f"  {ref:<6} {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
