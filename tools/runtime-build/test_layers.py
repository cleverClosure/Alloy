#!/usr/bin/env python3
"""Bounded layer writer controls. Author: Timur Isaev."""

import hashlib
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest

from inputs import BuildError, digest
from layers import cbor, file_table, write_layer


def decode_raw(data):
    if data[:5] != bytes.fromhex("28b52ffda0"):
        raise ValueError("wrong frame")
    expected, offset, output = int.from_bytes(data[5:9], "little"), 9, bytearray()
    while True:
        header = int.from_bytes(data[offset:offset + 3], "little")
        offset += 3
        if header & 6:
            raise ValueError("not raw")
        size = header >> 3
        output.extend(data[offset:offset + size])
        offset += size
        if header & 1:
            break
    if offset != len(data) or len(output) != expected:
        raise ValueError("truncated/trailing frame")
    return bytes(output)


class LayerTests(unittest.TestCase):
    def test_golden_independent_tar_and_deterministic_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            (source / "bin").mkdir(parents=True)
            tool = source / "bin/tool"
            tool.write_bytes(b"known runtime bytes\n")
            tool.chmod(0o755)
            (source / "alias").symlink_to("bin/tool")
            kwargs = dict(role="wine-runtime", revision="a" * 40, recipe_digest="sha256:" + "b" * 64)
            first = write_layer(source, root / "first.zst", **kwargs)
            os.utime(tool, (100, 100))
            second = write_layer(source, root / "second.zst", **kwargs)
            self.assertEqual(first, second)
            raw = decode_raw((root / "first.zst").read_bytes())
            with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
                metadata = json.load(archive.extractfile("layer.json"))
                table = archive.extractfile("metadata/file-table.cbor").read()
                self.assertEqual(metadata["fileTreeDigest"], "sha256:" + hashlib.sha256(table).hexdigest())
                self.assertEqual(table, cbor(file_table(source)))
                self.assertEqual(archive.extractfile("files/bin/tool").read(), tool.read_bytes())
                for entry in archive:
                    self.assertEqual((entry.uid, entry.gid, entry.mtime), (0, 0, 0))
            tool.write_bytes(b"known runtime byte!\n")
            third = write_layer(source, root / "third.zst", **kwargs)
            self.assertNotEqual(first["digest"], third["digest"])

    def test_unsafe_tree_rejected(self):
        for mutation in ("escape", "hardlink", "setid", "colon"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "file").write_bytes(b"x")
                if mutation == "escape":
                    (root / "bad").symlink_to("../outside")
                elif mutation == "hardlink":
                    os.link(root / "file", root / "other")
                elif mutation == "setid":
                    (root / "file").chmod(0o4755)
                else:
                    (root / "bad:name").write_bytes(b"x")
                with self.assertRaises(BuildError):
                    file_table(root)

    def test_committed_fixture_identity(self):
        fixture = Path(__file__).resolve().parents[2] / "runtime/content-store/Tests/AlloyContentStoreTests/LayerFixtures"
        if not fixture.exists():
            self.skipTest("extractor fixtures arrive in milestone 3")
        expected = json.loads((fixture / "descriptor.json").read_text())
        archive = fixture / "known.layer.tar.zst"
        self.assertEqual(expected["digest"], "sha256:" + digest(archive))
        with tarfile.open(fileobj=io.BytesIO(decode_raw(archive.read_bytes()))) as tar:
            self.assertEqual(tar.extractfile("files/bin/tool").read(), b"known runtime bytes\n")


if __name__ == "__main__":
    unittest.main()
