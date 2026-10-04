#!/usr/bin/env python3
"""Known-by-construction scratch Git controls. Author: Timur Isaev."""

import copy
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

import inventory


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wine-inventory-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "source"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Timur Isaev")
        self.git("config", "user.email", "fixture@example.invalid")
        self.base = self.commit("base.txt", "base\n", "upstream baseline")
        self.git("update-ref", "refs/remotes/origin/master", self.base)
        self.git("checkout", "-q", "-b", "alloy/spike-wine-001")
        self.first = self.commit("dlls/ntdll/fixture.txt", "primary\n", "primary change")
        self.git("branch", "alloy/alias")
        self.git("checkout", "-q", "-b", "alloy/side", self.base)
        self.second = self.commit("dlls/rpcrt4/fixture.txt", "side\n", "side change")
        self.git("checkout", "-q", "alloy/spike-wine-001")
        self.citation = self.root / "spikes/WINE-001/results/fixture.md"
        self.citation.parent.mkdir(parents=True)
        self.citation.write_text("# Fixture\n\n## Construction\n\nTwo independent downstream commits.\n")
        self.note = {
            "classification": "upstreamable",
            "status": "retained",
            "justification": "Constructed fixture with exactly one change on each independent branch.",
            "evidence": [{"path": "spikes/WINE-001/results/fixture.md", "heading": "## Construction"}],
        }
        self.policy = {
            "version": 1,
            "author": "Timur Isaev",
            "upstream_ref": "refs/remotes/origin/master",
            "expected_checkout": "alloy/spike-wine-001",
            "bounds": {"shared_commit_ids": 2, "supplemental_patches": 0, "total_maintenance_items": 2},
            "annotations": {self.first: copy.deepcopy(self.note), self.second: copy.deepcopy(self.note)},
            "supplemental": [],
        }

    def git(self, *args, repo=None, binary=False):
        result = subprocess.run(["git", "-C", str(repo or self.repo), *args], check=True, capture_output=True)
        return result.stdout if binary else result.stdout.decode().strip()

    def commit(self, relative, contents, subject, repo=None):
        path = (repo or self.repo) / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        self.git("add", "--", relative, repo=repo)
        self.git("-c", "commit.gpgsign=false", "commit", "-q", "-m", subject, repo=repo)
        return self.git("rev-parse", "HEAD", repo=repo)

    def generate(self):
        return inventory.generate(self.repo, self.root, self.policy)

    def output(self, result=None):
        directory = self.root / "output"
        inventory.write_outputs(result or self.generate(), directory, (self.repo,))
        return directory

    def test_known_union_deduplicates_alias_and_includes_side_branch(self):
        result = self.generate()
        self.assertEqual(result["counts"], {"shared_commit_ids": 2, "supplemental_patches": 0, "total_maintenance_items": 2})
        self.assertEqual(len(result["branches"]), 3)
        self.assertTrue(all(branch["count"] == 1 for branch in result["branches"]))
        self.assertEqual({entry["commit"] for entry in result["commits"]}, {self.first, self.second})
        self.assertEqual(result["upstream"]["commit"], self.base)
        first = next(entry for entry in result["commits"] if entry["commit"] == self.first)
        self.assertEqual(len(first["branches"]), 2)
        directory = self.output(result)
        inventory.check_outputs(result, directory)
        before = {p.name: p.read_bytes() for p in directory.iterdir()}
        self.output()
        self.assertEqual(before, {p.name: p.read_bytes() for p in directory.iterdir()})

    def test_dirty_staged_and_untracked_contents_do_not_enter_inventory(self):
        clean = self.generate()
        path = self.repo / "dlls/ntdll/fixture.txt"
        path.write_text("staged diagnostic\n")
        self.git("add", "dlls/ntdll/fixture.txt")
        path.write_text("unstaged diagnostic\n")
        (self.repo / "local-note").write_text("untracked\n")
        before = self.git("status", "--porcelain=v1", binary=True)
        index = (self.repo / ".git/index").read_bytes()
        self.assertEqual(self.generate(), clean)
        self.assertEqual(before, self.git("status", "--porcelain=v1", binary=True))
        self.assertEqual(index, (self.repo / ".git/index").read_bytes())
        self.assertEqual(path.read_text(), "unstaged diagnostic\n")

    def test_undocumented_side_commit_fails_closed(self):
        self.git("checkout", "-q", "alloy/side")
        self.commit("side-extra.txt", "new\n", "new side change")
        self.git("checkout", "-q", "alloy/spike-wine-001")
        with self.assertRaisesRegex(inventory.Invalid, "annotation:undocumented_commit:"):
            self.generate()

    def test_stale_annotation_is_rejected(self):
        self.policy["annotations"]["a" * 40] = copy.deepcopy(self.note)
        with self.assertRaisesRegex(inventory.Invalid, "annotation:stale_commit:"):
            self.generate()

    def test_each_ceiling_accepts_boundary_and_rejects_growth(self):
        counts = {"shared_commit_ids": 2, "supplemental_patches": 1, "total_maintenance_items": 3}
        inventory.bound(counts, counts)
        for key in counts:
            with self.subTest(key=key):
                limits = dict(counts)
                limits[key] -= 1
                with self.assertRaisesRegex(inventory.Invalid, "bound:" + key):
                    inventory.bound(counts, limits)
        self.policy["bounds"]["shared_commit_ids"] = 1
        with self.assertRaisesRegex(inventory.Invalid, "bound:shared_commit_ids:observed_2:limit_1"):
            self.generate()

    def test_committed_outputs_fail_on_either_edit(self):
        result = self.generate()
        for name in ("inventory.json", "INVENTORY.md"):
            with self.subTest(name=name):
                directory = self.output(result)
                path = directory / name
                path.write_text(path.read_text() + "edited\n")
                with self.assertRaisesRegex(inventory.Invalid, "inventory:drift:" + name):
                    inventory.check_outputs(result, directory)

    def test_branch_set_and_cached_upstream_drift_change_output(self):
        directory = self.output()
        self.git("branch", "alloy/new-alias")
        with self.assertRaisesRegex(inventory.Invalid, "inventory:drift:"):
            inventory.check_outputs(self.generate(), directory)
        self.git("branch", "-D", "alloy/new-alias")
        self.git("checkout", "-q", "main")
        upstream = self.commit("new-upstream.txt", "upstream\n", "new cached upstream")
        self.git("update-ref", "refs/remotes/origin/master", upstream)
        self.git("checkout", "-q", "alloy/spike-wine-001")
        with self.assertRaisesRegex(inventory.Invalid, "inventory:drift:"):
            inventory.check_outputs(self.generate(), directory)

    def test_missing_evidence_section_is_rejected(self):
        self.citation.write_text("# Fixture\n\n## Renamed\n")
        with self.assertRaisesRegex(inventory.Invalid, "citation:missing_section:"):
            self.generate()

    def test_excluded_path_metadata_stops_before_patch_reads(self):
        commit = self.commit("dlls/d3d12/fixture.txt", "invented fixture, not third-party code\n", "excluded path fixture")
        self.policy["annotations"][commit] = copy.deepcopy(self.note)
        with self.assertRaisesRegex(inventory.Invalid, "path:excluded_source"):
            self.generate()

    def test_malformed_policy_and_duplicate_json_are_rejected(self):
        for mutate, reason in (
            (lambda p: p.update(extra=True), "policy:invalid_fields"),
            (lambda p: p.update(version=True), "policy:unsupported_version"),
            (lambda p: p["bounds"].update(shared_commit_ids=True), "bound:invalid_number"),
            (lambda p: p["annotations"][self.first].update(classification="approved-upstream"), "annotation:invalid_classification"),
        ):
            with self.subTest(reason=reason):
                policy = copy.deepcopy(self.policy)
                mutate(policy)
                with self.assertRaisesRegex(inventory.Invalid, reason):
                    inventory.validate_policy(policy, self.root)
        path = self.root / "duplicate.json"
        path.write_text('{"version":1,"version":1}')
        with self.assertRaisesRegex(inventory.Invalid, "policy:duplicate_key:"):
            inventory.load(path)

    def test_outputs_cannot_write_shared_repository_or_follow_file_symlink(self):
        result = self.generate()
        for directory in (self.repo, self.repo / "nested", self.root / "source-alias"):
            if directory.name == "source-alias":
                directory.symlink_to(self.repo, target_is_directory=True)
            with self.subTest(directory=directory):
                with self.assertRaisesRegex(inventory.Invalid, "output:inside_source_repository"):
                    inventory.write_outputs(result, directory, (self.repo,))
        directory = self.root / "unsafe-output"
        directory.mkdir()
        target = self.repo / "base.txt"
        (directory / "inventory.json").symlink_to(target)
        with self.assertRaisesRegex(inventory.Invalid, "output:symlink"):
            inventory.write_outputs(result, directory, (self.repo,))
        self.assertEqual(target.read_text(), "base\n")

    def test_isolated_patch_counted_once_and_exact_correspondence_checked(self):
        private = self.root / "private-source"
        self.git("clone", "-q", "--no-hardlinks", str(self.repo), str(private))
        self.git("config", "user.name", "Timur Isaev", repo=private)
        self.git("config", "user.email", "fixture@example.invalid", repo=private)
        self.git("checkout", "-q", "-b", "alloy/isolated", repo=private)
        commit = self.commit("dlls/ntdll/private-fixture.txt", "isolated patch\n", "isolated change", repo=private)
        patch = self.root / "spikes/WINE-001/fixture.patch"
        patch.write_bytes(self.git("diff", "--no-ext-diff", "--no-textconv", "--binary", self.first, commit, repo=private, binary=True))
        note = copy.deepcopy(self.note)
        note["status"] = "isolated-not-promoted"
        self.policy["supplemental"] = [{"commit": commit, "parent": self.first, "branch": "alloy/isolated", "patch": "spikes/WINE-001/fixture.patch", "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(), "annotation": note}]
        self.policy["bounds"].update(supplemental_patches=1, total_maintenance_items=3)
        result = self.generate()
        self.assertEqual(result["counts"]["total_maintenance_items"], 3)
        self.assertFalse(result["supplemental"][0]["in_shared_history"])
        inventory.verify_isolated(private, self.root, result)
        # If explicitly imported into another retained branch, its history and
        # its tracked patch remain one maintenance entry rather than two.
        self.git("fetch", "-q", str(private), "alloy/isolated:refs/heads/alloy/imported")
        self.policy["bounds"]["shared_commit_ids"] = 3
        imported = self.generate()
        self.assertEqual(imported["counts"], {"shared_commit_ids": 3, "supplemental_patches": 0, "total_maintenance_items": 3})
        altered = copy.deepcopy(result)
        altered["supplemental"][0]["patch_sha256"] = "0" * 64
        with self.assertRaisesRegex(inventory.Invalid, "isolated:patch_mismatch"):
            inventory.verify_isolated(private, self.root, altered)
        patch.write_bytes(patch.read_bytes() + b"edit\n")
        with self.assertRaisesRegex(inventory.Invalid, "supplemental:patch_changed"):
            self.generate()


if __name__ == "__main__":
    unittest.main()
