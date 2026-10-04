#!/usr/bin/env python3
"""Committed Wine fork inventory; shared checkouts are read-only. Author: Timur Isaev."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


class Invalid(ValueError):
    """Named inventory failure."""


def require(condition, reason):
    if not condition:
        raise Invalid(reason)


def canonical(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def load(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"policy:duplicate_key:{key}")
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs)


def fields(value, keys, label):
    require(type(value) is dict and set(value) == set(keys), f"{label}:invalid_fields")


def oid(value):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{40}", value), "commit:invalid_id")


def safe_path(value):
    require(type(value) is str and value and not PurePosixPath(value).is_absolute(), "path:invalid")
    require(all(part not in ("", ".", "..") for part in value.split("/")) and "\\" not in value and not any(ord(char) < 32 for char in value), "path:invalid")
    parts = value.lower().split("/")
    require(not any(part == "d3d12" or part.startswith("vkd3d") for part in parts), "path:excluded_source")
    return value


def first_party(root, relative):
    safe_path(relative)
    require(relative.startswith("spikes/"), "evidence:not_first_party")
    path = Path(root)
    for part in relative.split("/"):
        path = path / part
        require(not path.is_symlink(), "evidence:symlink")
    require(path.is_file(), f"evidence:missing_file:{relative}")
    return path


def git(repo, *args, binary=False):
    # Do not refresh a shared index, run fsmonitor hooks, or honor injected Git
    # routing variables. Every production command below is metadata/read-only.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", LC_ALL="C", LANG="C")
    result = subprocess.run(["git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", str(repo), *args], env=env, capture_output=True, check=False, timeout=30)
    require(result.returncode == 0, f"git:command_failed:{args[0]}:{result.stderr.decode(errors='replace').strip()}")
    return result.stdout if binary else result.stdout.decode().strip()


def metadata(repo, policy):
    require(Path(repo).is_dir(), "wine:missing_repository")
    branch = git(repo, "symbolic-ref", "--short", "HEAD")
    require(branch == policy["expected_checkout"], "wine:unexpected_checkout")
    refs = {}
    for line in git(repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/alloy/").splitlines():
        name, commit = line.split()
        oid(commit)
        refs[name] = commit
    require(bool(refs), "wine:no_alloy_branches")
    upstream = git(repo, "rev-parse", "--verify", f"{policy['upstream_ref']}^{{commit}}")
    oid(upstream)
    return {"checkout": branch, "head": git(repo, "rev-parse", "HEAD"), "upstream": upstream, "refs": refs}


def annotation(value, root):
    fields(value, ("classification", "justification", "status", "evidence"), "annotation")
    kind = value["classification"]
    require(type(kind) is str and (kind in ("upstreamable", "Alloy-specific") or re.fullmatch(r"temporary-pending-[a-z0-9-]+", kind)), "annotation:invalid_classification")
    require(value["status"] in ("retained", "reverted-experiment", "revert-of-experiment", "isolated-not-promoted"), "annotation:invalid_status")
    require(type(value["justification"]) is str and len(value["justification"]) >= 30, "annotation:missing_justification")
    require(type(value["evidence"]) is list and bool(value["evidence"]), "annotation:missing_evidence")
    for citation in value["evidence"]:
        fields(citation, ("path", "heading"), "citation")
        require(type(citation["heading"]) is str and citation["heading"].startswith("#"), "citation:invalid_heading")
        path = first_party(root, citation["path"])
        require(citation["heading"] in path.read_text().splitlines(), f"citation:missing_section:{citation['path']}:{citation['heading']}")


def validate_policy(policy, root):
    fields(policy, ("version", "author", "upstream_ref", "expected_checkout", "bounds", "annotations", "supplemental"), "policy")
    require(type(policy["version"]) is int and policy["version"] == 1, "policy:unsupported_version")
    require(policy["author"] == "Timur Isaev", "policy:invalid_author")
    require(policy["upstream_ref"] == "refs/remotes/origin/master", "policy:unsupported_upstream")
    require(policy["expected_checkout"] == "alloy/spike-wine-001", "policy:unsupported_checkout")
    fields(policy["bounds"], ("shared_commit_ids", "supplemental_patches", "total_maintenance_items"), "bounds")
    for bound in policy["bounds"].values():
        require(type(bound) is int and bound >= 0, "bound:invalid_number")
    require(type(policy["annotations"]) is dict, "annotations:wrong_type")
    for commit, item in policy["annotations"].items():
        oid(commit)
        annotation(item, root)
    require(type(policy["supplemental"]) is list, "supplemental:wrong_type")
    seen = set()
    for item in policy["supplemental"]:
        fields(item, ("commit", "parent", "branch", "patch", "patch_sha256", "annotation"), "supplemental")
        oid(item["commit"])
        oid(item["parent"])
        require(item["commit"] not in seen and item["commit"] not in policy["annotations"], "supplemental:duplicate_commit")
        seen.add(item["commit"])
        require(type(item["branch"]) is str and item["branch"].startswith("alloy/"), "supplemental:invalid_branch")
        require(type(item["patch_sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", item["patch_sha256"]), "supplemental:invalid_digest")
        patch = first_party(root, item["patch"])
        require(hashlib.sha256(patch.read_bytes()).hexdigest() == item["patch_sha256"], "supplemental:patch_changed")
        annotation(item["annotation"], root)


def bound(counts, limits):
    for name, count in counts.items():
        require(count <= limits[name], f"bound:{name}:observed_{count}:limit_{limits[name]}")


def generate(wine, root, policy):
    validate_policy(policy, root)
    before = metadata(wine, policy)
    branches = []
    membership = {}
    for ref, tip in sorted(before["refs"].items()):
        bases = git(wine, "merge-base", "--all", before["upstream"], tip).splitlines()
        require(len(bases) == 1, f"branch:ambiguous_merge_base:{ref}")
        # Subtract all upstream ancestry; metadata also names the merge-base
        # used by an independent per-branch recount.
        commits = sorted(git(wine, "rev-list", tip, "--not", before["upstream"]).splitlines())
        branches.append({"ref": ref, "tip": tip, "merge_base": bases[0], "downstream_commit_ids": commits, "count": len(commits)})
        for commit in commits:
            membership.setdefault(commit, []).append(ref)
    annotations = dict(policy["annotations"])
    for item in policy["supplemental"]:
        annotations[item["commit"]] = item["annotation"]
    require(not (set(membership) - set(annotations)), "annotation:undocumented_commit:" + ",".join(sorted(set(membership) - set(annotations))))
    require(not (set(policy["annotations"]) - set(membership)), "annotation:stale_commit:" + ",".join(sorted(set(policy["annotations"]) - set(membership))))
    entries = []
    for commit in sorted(membership):
        oid(commit)
        paths = sorted(filter(None, git(wine, "diff-tree", "--root", "--no-commit-id", "--name-only", "--no-renames", "-r", commit).splitlines()))
        require(bool(paths), "commit:empty_or_merge_requires_review")
        for path in paths:
            safe_path(path)
        parents = git(wine, "show", "-s", "--format=%P", commit).split()
        require(len(parents) == 1, "commit:merge_requires_review")
        entries.append({"commit": commit, "parents": parents, "subject": git(wine, "show", "-s", "--format=%s", commit), "paths": paths, "branches": membership[commit], **annotations[commit]})
    supplemental = []
    for item in policy["supplemental"]:
        require(git(wine, "rev-parse", "--verify", f"{item['parent']}^{{commit}}") == item["parent"], "supplemental:base_missing")
        # The checked-in first-party patch is a maintained artifact even if its
        # isolated source checkout is not installed on this machine.
        paths = []
        for line in first_party(root, item["patch"]).read_text().splitlines():
            if line.startswith("diff --git "):
                match = re.fullmatch(r"diff --git a/(\S+) b/(\S+)", line)
                require(match is not None, "supplemental:unsupported_patch_path")
                safe_path(match.group(1))
                paths.append(safe_path(match.group(2)))
        require(bool(paths) and len(paths) == len(set(paths)), "supplemental:invalid_patch")
        supplemental.append({**item, "paths": sorted(paths), "in_shared_history": item["commit"] in membership})
    counts = {"shared_commit_ids": len(entries), "supplemental_patches": sum(not item["in_shared_history"] for item in supplemental)}
    counts["total_maintenance_items"] = sum(counts.values())
    bound(counts, policy["bounds"])
    require(metadata(wine, policy) == before, "wine:references_changed_during_inventory")
    return {
        "version": 1, "author": "Timur Isaev", "scope": "committed-Wine-alloy-branches-plus-explicit-isolated-patches",
        "counting": "distinct commit IDs; retained side branches and reverted history included; supplemental patch and matching isolated commit counted once",
        "upstream": {"ref": policy["upstream_ref"], "commit": before["upstream"], "commit_time": git(wine, "show", "-s", "--format=%cI", before["upstream"]), "freshness": "cached-ref; no fetch or rebase performed"},
        "checkout": {"branch": before["checkout"], "head": before["head"]}, "working_tree": "uncommitted changes excluded from all counts and patch contents",
        "bounds": policy["bounds"], "counts": counts, "branches": branches, "commits": entries, "supplemental": supplemental,
    }


def verify_isolated(repo, root, inventory):
    """Optional exact patch correspondence; never checks out or writes sources."""
    for item in inventory["supplemental"]:
        require(git(repo, "rev-parse", f"refs/heads/{item['branch']}") == item["commit"], "isolated:branch_mismatch")
        require(git(repo, "show", "-s", "--format=%P", item["commit"]) == item["parent"], "isolated:parent_mismatch")
        paths = sorted(git(repo, "diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", item["commit"]).splitlines())
        for path in paths:
            safe_path(path)
        require(paths == item["paths"], "isolated:paths_mismatch")
        patch = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--binary", item["parent"], item["commit"], "--", *paths, binary=True)
        require(hashlib.sha256(patch).hexdigest() == item["patch_sha256"], "isolated:patch_mismatch")


def markdown(inventory):
    counts = inventory["counts"]
    lines = ["<!-- Author: Timur Isaev -->", "", "# Generated Wine downstream inventory", "", "Generated by `inventory.py`; edit `annotations.json` and regenerate, never this file.", "", f"**{counts['shared_commit_ids']} shared commit IDs + {counts['supplemental_patches']} isolated patch = {counts['total_maintenance_items']} maintenance entries.**", "", "Counts deduplicate commit IDs across retained branches, not textual patches. Reverted", "experiments and their reversions stay visible; these are history/replay counts,", "not a claim that every entry is an active behavioral difference. `upstreamable`", "means an engineering candidate, not reviewed, submitted, or accepted upstream.", "", f"Cached upstream: `{inventory['upstream']['commit']}` ({inventory['upstream']['commit_time']}).", "No fresh upstream fetch, replay, build, or guest test is claimed by this inventory.", "Uncommitted working-tree changes are excluded.", "", "## Retained branches", "", "| Branch | Tip | Downstream IDs |", "| --- | --- | ---: |"]
    for branch in inventory["branches"]:
        lines.append(f"| `{branch['ref'].removeprefix('refs/heads/')}` | `{branch['tip'][:12]}` | {branch['count']} |")
    lines += ["", "## Shared committed changes", ""]
    for entry in inventory["commits"]:
        lines += [f"### `{entry['commit'][:12]}` — {entry['subject'].rstrip('.,;:!?')}", "", f"- Classification: **{entry['classification']}**; history status: `{entry['status']}`.", f"- Why: {entry['justification']}", "- Evidence:"]
        for citation in entry["evidence"]:
            relative = os.path.relpath(ROOT / citation["path"], HERE)
            lines.append(f"  [{citation['path']}]({relative}), {citation['heading'].lstrip('# ')}.")
        lines += [f"- Changed paths: {', '.join('`' + path + '`' for path in entry['paths'])}.", ""]
    lines += ["## Isolated supplemental maintenance", ""]
    for item in inventory["supplemental"]:
        lines += [f"### `{item['commit'][:12]}` — `{item['branch']}`", "", f"Parent: `{item['parent']}`. Present in shared branch history: **{str(item['in_shared_history']).lower()}**.", "", f"Patch: `{item['patch']}`; SHA-256 `{item['patch_sha256']}`.", "", f"Classification: **{item['annotation']['classification']}**.", "", item["annotation"]["justification"], ""]
        for citation in item["annotation"]["evidence"]:
            relative = os.path.relpath(ROOT / citation["path"], HERE)
            lines += [f"Evidence: [{citation['path']}]({relative}), {citation['heading'].lstrip('# ')}.", ""]
    lines += ["## Enforced ceiling", "", f"Shared commit IDs ≤ {inventory['bounds']['shared_commit_ids']}; supplemental patches ≤ {inventory['bounds']['supplemental_patches']}; total maintenance entries ≤ {inventory['bounds']['total_maintenance_items']}.", "", "Unknown commits, missing citations, changed patch bytes, bound growth, and stale", "generated output fail the check. Raising a ceiling requires an explicit reviewed", "annotation/bound update and regenerated evidence. Full drill triggers remain in", "[WINE-001 result 09](../results/2026-07-24-09-first-rebase-drill.md).", ""]
    return "\n".join(lines)


def check_outputs(inventory, directory):
    for name, expected in (("inventory.json", canonical(inventory)), ("INVENTORY.md", markdown(inventory))):
        path = Path(directory) / name
        require(path.is_file() and not path.is_symlink() and path.read_text() == expected, f"inventory:drift:{name}")


def write_outputs(inventory, directory, repositories):
    destination = Path(directory).resolve()
    for repository in repositories:
        if repository is not None:
            source = Path(repository).resolve()
            require(destination != source and source not in destination.parents, "output:inside_source_repository")
    for name in ("inventory.json", "INVENTORY.md"):
        require(not (destination / name).is_symlink(), "output:symlink")
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "inventory.json").write_text(canonical(inventory))
    (destination / "INVENTORY.md").write_text(markdown(inventory))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("generate", "check"))
    parser.add_argument("--wine", type=Path, default=Path(os.environ.get("ALLOY_WINE_SOURCE", ROOT / "third_party/src/wine")))
    parser.add_argument("--annotations", type=Path, default=HERE / "annotations.json")
    parser.add_argument("--output", type=Path, default=HERE)
    parser.add_argument("--isolated-wine", type=Path)
    args = parser.parse_args()
    try:
        policy = load(args.annotations)
        result = generate(args.wine, ROOT, policy)
        if args.isolated_wine:
            verify_isolated(args.isolated_wine, ROOT, result)
        if args.action == "generate":
            write_outputs(result, args.output, (args.wine, args.isolated_wine))
        else:
            check_outputs(result, args.output)
        # Tracked dirt is reported separately, never made part of generated data.
        dirty = git(args.wine, "status", "--porcelain=v1", "--untracked-files=no", binary=True).decode().splitlines()
        print(json.dumps({"status": "PASS", "action": args.action, "counts": result["counts"], "branches": len(result["branches"]), "uncommitted_status_excluded": dirty, "isolated_correspondence": "verified" if args.isolated_wine else "not-requested"}, sort_keys=True))
    except (Invalid, OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"FAIL {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
