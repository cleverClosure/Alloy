"""ADR path and real apply controls on inert fixtures. Author: Timur Isaev."""
import subprocess
import tempfile
import unittest
from pathlib import Path

import dxmt_inventory as inventory

PATH = 'src/d3d11/fixture.cpp'
PATCH = f'''diff --git a/{PATH} b/{PATH}
index 3367afd..3e75765 100644
--- a/{PATH}
+++ b/{PATH}
@@ -1 +1 @@
-old
+new
'''.encode()


class DXMTInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'source'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Timur Isaev')
        self.git('config', 'user.email', 'test@example.invalid')
        (self.repo / PATH).parent.mkdir(parents=True)
        (self.repo / PATH).write_text('old\n')
        (self.repo / 'unrelated.txt').write_text('must never materialize\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'known fixture')
        self.base = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.DEVNULL).decode().strip()

    def test_literal_patch_applies_and_source_stays_unchanged(self):
        report = inventory.apply_check(self.repo, self.base, [PATCH])
        self.assertEqual(report['status'], 'clean')
        self.assertEqual(report['allowed_paths'], [PATH])
        self.assertEqual(report['materialized_paths'], [PATH])
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual((self.repo / PATH).read_text(), 'old\n')

    def test_corrupted_hunk_is_real_apply_failure(self):
        for patch in (PATCH.replace(b'-old', b'-absent'), PATCH.replace(b'@@ -1 +1 @@', b'@@ -1,7 +1,3 @@')):
            with self.subTest(patch=patch):
                self.assertEqual(inventory.apply_check(self.repo, self.base, [patch])['status'], 'conflict')

    def test_excluded_paths_rejected_before_repository_access(self):
        for path in ('src/d3d12/fake.cpp', 'vkd3d/fake.cpp', 'src/vkd3d-proton/fake.cpp', 'src/d3d11/vkd3d-extra/fake.cpp'):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'excluded_source'):
                inventory.apply_check(self.root / 'does-not-exist', self.base, [PATCH.replace(PATH.encode(), path.encode())])

    def test_secondary_header_cannot_bypass_guard(self):
        patch = PATCH.replace(('+++ b/' + PATH).encode(), b'+++ b/src/d3d12/fake.cpp')
        with self.assertRaisesRegex(ValueError, 'excluded_source'):
            inventory.patch_paths(patch)

    def test_traversal_quoted_and_non_d3d11_paths_rejected(self):
        for path in ('src/d3d11/../../escaped.cpp', 'src/d3d11/./a.cpp', 'src/d3d11/a\\b.cpp', 'other/file.cpp', 'src/d3d11/"fake.cpp'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                inventory.patch_paths(PATCH.replace(PATH.encode(), path.encode()))

    def test_rename_copy_binary_symlink_submodule_rejected(self):
        for metadata in ('rename from src/d3d12/fake.cpp', 'copy from old', 'GIT binary patch', 'new file mode 120000', 'index a..b 160000'):
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                inventory.patch_paths(PATCH + metadata.encode() + b'\n')

    def test_duplicate_or_inconsistent_header_rejected(self):
        for patch in (PATCH + PATCH, PATCH.replace(b'+++ b/', b'+++ a/'), PATCH.replace(('+++ b/' + PATH).encode(), b'+++ b/src/d3d11/different.cpp')):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                inventory.patch_paths(patch)

    def test_allowlisted_symlink_source_rejected_before_checkout(self):
        (self.repo / PATH).unlink()
        (self.repo / PATH).symlink_to('../../unrelated.txt')
        self.git('add', PATH)
        self.git('commit', '-qm', 'symlink fixture')
        with self.assertRaisesRegex(ValueError, 'allowlist:non_regular_file'):
            inventory.apply_check(self.repo, self.git('rev-parse', 'HEAD'), [PATCH])

    def test_patch_new_regular_file(self):
        path = 'src/d3d11/new.cpp'
        patch = f'diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n@@ -0,0 +1 @@\n+fixture\n'.encode()
        result = inventory.apply_check(self.repo, self.base, [patch])
        self.assertEqual(result['status'], 'clean')
        self.assertEqual(result['materialized_paths'], [])

    def test_output_drift_and_source_guard(self):
        output = self.root / 'out'
        report = {'known': 2}
        inventory.outputs(report, output, 'generate', self.repo)
        inventory.outputs(report, output, 'check', self.repo)
        with self.assertRaisesRegex(ValueError, 'inventory:drift'):
            inventory.outputs({'known': 3}, output, 'check', self.repo)
        with self.assertRaisesRegex(ValueError, 'output:inside_source'):
            inventory.outputs(report, self.repo, 'generate', self.repo)


if __name__ == '__main__':
    unittest.main()
