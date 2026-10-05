#!/usr/bin/env python3
"""Adversarial reproducibility gate controls. Author: Timur Isaev."""

import json
from pathlib import Path
import struct
import tempfile
import unittest

from inputs import BuildError
from reproduce import compare_trees, normalize_metal, verify_package_copy

HERE = Path(__file__).resolve().parent


def synthetic_macho(root, marker):
    header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6, 2, 40, 0, 0)
    uuid = struct.pack("<2I", 0x1B, 24) + bytes([marker]) * 16
    body = b"stable machine code\0" + b"\0".join(
        str(root).encode() + f"/sources/dxmt/src/airconv/shaders/{name}.metal".encode()
        for name in ("air_msad", "air_samplepos", "air_tessellation"))
    start = 72 + len(body)
    pages = (start + 4095) // 4096
    directory_size = 101 + pages * 32
    directory = (struct.pack(">9I", 0xFADE0C02, directory_size, 0x20400, 0x20002, 101, 88, 0, pages, start)
                 + bytes((32, 2, 0, 12)) + b"\0" * 48 + b"winemetal.so\0" + bytes([marker]) * (pages * 32))
    signature_bytes = struct.pack(">5I", 0xFADE0CC0, 20 + directory_size, 1, 0, 20) + directory
    signature = struct.pack("<4I", 0x1D, 16, start, len(signature_bytes))
    return header + uuid + signature + body + signature_bytes


class ReproduceTests(unittest.TestCase):
    def test_package_metadata_mutation_and_extra_artifact_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected, actual = [Path(temporary) / name for name in ("expected", "actual")]
            for root in (expected, actual):
                root.mkdir()
                (root / "sbom.json").write_bytes(b'{"known":1}')
                (root / "sbom.json").chmod(0o444)
            actual.chmod(0o555)
            try:
                self.assertEqual(len(verify_package_copy(expected, actual)), 1)
                (actual / "sbom.json").chmod(0o644)
                (actual / "sbom.json").write_bytes(b'{"known":2}')
                (actual / "sbom.json").chmod(0o444)
                with self.assertRaisesRegex(BuildError, "artifact differs"):
                    verify_package_copy(expected, actual)
                actual.chmod(0o755)
                (actual / "extra").write_bytes(b"x")
                actual.chmod(0o555)
                with self.assertRaisesRegex(BuildError, "artifact sets"):
                    verify_package_copy(expected, actual)
            finally:
                actual.chmod(0o755)

    def test_identical_and_unlisted_difference(self):
        with tempfile.TemporaryDirectory() as temporary:
            roots = [Path(temporary) / name for name in ("first", "other")]
            for root in roots:
                root.mkdir()
                (root / "file").write_bytes(b"known")
            trees = [{"wine-runtime": root} for root in roots]
            self.assertTrue(compare_trees(*trees, roots, [])["byteIdentical"])
            (roots[1] / "file").write_bytes(b"knOwn")
            with self.assertRaisesRegex(BuildError, "unlisted"):
                compare_trees(*trees, roots, [])
            (roots[1] / "extra").write_bytes(b"x")
            with self.assertRaisesRegex(BuildError, "path sets"):
                compare_trees(*trees, roots, [])

    def test_exception_is_bounded_to_known_path_and_derived_fields(self):
        rules = json.loads((HERE / "repro-exemptions.json").read_text())["exceptions"]
        with tempfile.TemporaryDirectory() as temporary:
            roots = [Path(temporary) / name for name in ("first", "other")]
            files = []
            for index, root in enumerate(roots):
                file = root / "providers/aarch64-unix/winemetal.so"
                file.parent.mkdir(parents=True)
                file.write_bytes(synthetic_macho(root, index + 1))
                files.append(file)
            trees = [{"graphics-provider": root} for root in roots]
            # Synthetic Mach-O tests parsing only; production comparison always verifies codesign.
            result = compare_trees(*trees, roots, rules, verify_signatures=False)
            self.assertEqual(len(result["explainedDifferences"]), 1)
            self.assertFalse(result["byteIdentical"])
            original = files[1].read_bytes()
            files[1].write_bytes(original.replace(b"winemetal.so\0", b"winemetaL.so\0"))
            with self.assertRaisesRegex(BuildError, "signature CodeDirectory"):
                compare_trees(*trees, roots, rules, verify_signatures=False)
            files[1].write_bytes(original)
            data = files[1].read_bytes().replace(b"stable machine code", b"stAble machine code")
            files[1].write_bytes(data)
            with self.assertRaisesRegex(BuildError, "exceeds declared cause"):
                compare_trees(*trees, roots, rules, verify_signatures=False)

    def test_missing_path_and_invalid_macho_refused(self):
        root = Path("/private/tmp/first")
        for bytes_ in (b"bad", bytes.fromhex("cffaedfe"),
                       synthetic_macho(root, 1).replace(b"air_msad", b"air_nope")):
            with self.assertRaises(BuildError):
                normalize_metal(bytes_, root)


if __name__ == "__main__":
    unittest.main()
