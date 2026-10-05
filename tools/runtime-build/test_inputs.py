#!/usr/bin/env python3
"""Independent pin/export controls; no runtime build. Author: Timur Isaev."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from inputs import BuildError, check_digest, excluded, export_objects, git_entries, tree_digest


class InputsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Timur Isaev")
        self.git("config", "user.email", "fixture@example.invalid")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE).decode().strip()

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_pinned_export_ignores_dirty_and_switched_checkout(self):
        (self.repo / "code.c").write_text("committed\n")
        first = self.commit()
        (self.repo / "code.c").write_text("different commit\n")
        second = self.commit()
        (self.repo / "code.c").write_text("dirty\n")
        export_objects(self.repo, first, self.root / "one", {})
        export_objects(self.repo, second, self.root / "two", {})
        self.assertEqual((self.root / "one/code.c").read_text(), "committed\n")
        self.assertEqual((self.root / "two/code.c").read_text(), "different commit\n")
        self.assertEqual((self.repo / "code.c").read_text(), "dirty\n")
        self.assertNotEqual(tree_digest(self.root / "one"), tree_digest(self.root / "two"))

    def test_forbidden_blobs_are_not_requested(self):
        # Remove the object after commit: requesting even one excluded blob now
        # fails. This tests omission before reading, rather than after export.
        for relative in ("src/d3d12/forbidden", "libs/vkd3d/forbidden", "vkd3d-proton/no"):
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("excluded fixture: " + relative)
        (self.repo / "allowed").write_text("known answer")
        revision = self.commit()
        for relative in ("src/d3d12/forbidden", "libs/vkd3d/forbidden", "vkd3d-proton/no"):
            oid = self.git("rev-parse", revision + ":" + relative)
            (self.repo / ".git/objects" / oid[:2] / oid[2:]).unlink()
        export_objects(self.repo, revision, self.root / "out", {})
        self.assertEqual((self.root / "out/allowed").read_text(), "known answer")
        self.assertFalse((self.root / "out/src").exists())

    def test_one_byte_toolchain_mutation_rejected(self):
        archive = self.root / "archive"
        archive.write_bytes(b"pinned toolchain")
        known = hashlib.sha256(b"pinned toolchain").hexdigest()
        check_digest(archive, known)
        archive.write_bytes(b"Pinned toolchain")
        with self.assertRaisesRegex(BuildError, "digest mismatch"):
            check_digest(archive, known)

    def test_mutable_revision_rejected(self):
        with self.assertRaises(BuildError):
            git_entries(self.repo, "HEAD")

    def test_wrong_submodule_pin_rejected(self):
        (self.repo / "file").write_text("fixture")
        revision = self.commit()
        with self.assertRaisesRegex(BuildError, "submodule pin"):
            export_objects(self.repo, revision, self.root / "out", {"sub": "0" * 40})

    def test_source_link_escape_rejected(self):
        (self.repo / "escape").symlink_to("../outside")
        revision = self.commit()
        with self.assertRaisesRegex(BuildError, "symlink escapes"):
            export_objects(self.repo, revision, self.root / "out", {})

    def test_modes_and_internal_links_preserved(self):
        (self.repo / "tool").write_bytes(b"#!/bin/sh\nexit 42\n")
        (self.repo / "tool").chmod(0o755)
        (self.repo / "alias").symlink_to("tool")
        revision = self.commit()
        export_objects(self.repo, revision, self.root / "out", {})
        self.assertEqual((self.root / "out/tool").stat().st_mode & 0o777, 0o755)
        self.assertTrue((self.root / "out/alias").is_symlink())


if __name__ == "__main__":
    unittest.main()
