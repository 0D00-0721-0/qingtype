"""Version source, bundle generation, validation, and release tag regressions."""
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        for folder in ('scripts', 'resources'):
            (self.root / folder).mkdir()
        for name in ('make-bundles.py', 'version.py', 'package-app.sh'):
            shutil.copy(ROOT / 'scripts' / name, self.root / 'scripts')
        shutil.copy(ROOT / 'resources/Info.plist', self.root / 'resources')
        (self.root / 'VERSION').write_text('7.8.9\n')
        self.app = self.root / 'QingType.app'
        self.settings = self.app / 'Contents/Applications/QingType Settings.app'
        for bundle in (self.app, self.settings):
            (bundle / 'Contents').mkdir(parents=True, exist_ok=True)

    def run_script(self, name, *args, ok=True):
        result = subprocess.run([sys.executable, str(self.root / 'scripts' / name), *map(str, args)],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result.stdout.strip()

    def generate(self):
        self.run_script('make-bundles.py', self.app, self.settings)

    def test_source_controls_both_bundle_versions(self):
        self.generate()
        for bundle in (self.app, self.settings):
            info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleShortVersionString'], '7.8.9')
            self.assertEqual(info['CFBundleVersion'], '7.8.9')
        self.run_script('version.py', 'check-bundles', self.app, self.settings)
        self.assertEqual(self.run_script('version.py', 'package-name', 'arm64'), 'QingType-7.8.9-arm64.dmg')

    def test_mismatched_or_missing_bundle_versions_are_rejected(self):
        self.generate()
        path = self.settings / 'Contents/Info.plist'
        original = plistlib.loads(path.read_bytes())
        for key, value in [('CFBundleShortVersionString', '7.8.8'), ('CFBundleVersion', '7.8.8'), ('CFBundleVersion', None)]:
            info = original.copy()
            if value is None:
                del info[key]
            else:
                info[key] = value
            path.write_bytes(plistlib.dumps(info))
            self.run_script('version.py', 'check-bundles', self.app, self.settings, ok=False)

    def test_bad_version_and_release_tags_are_rejected(self):
        for value in ('7.8', '7.8.9-preview.1', '07.8.9', '7.8.9\n8.0.0', ''):
            (self.root / 'VERSION').write_text(value)
            self.run_script('version.py', 'read', ok=False)
        (self.root / 'VERSION').write_text('7.8.9\n')
        self.run_script('version.py', 'check-tag', 'v7.8.9-preview.1')
        for tag in ('v7.8.8-preview.1', 'v7.8.9-preview.1-extra', 'v7.8.9-preview.', 'v7.8.9'):
            self.run_script('version.py', 'check-tag', tag, ok=False)

    def test_packaging_rejects_a_stale_build_before_creating_output(self):
        self.generate()
        (self.root / 'build').mkdir()
        shutil.copytree(self.app, self.root / 'build/QingType.app')
        (self.root / 'VERSION').write_text('7.8.10\n')
        result = subprocess.run(['bash', str(self.root / 'scripts/package-app.sh')], cwd=self.root,
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Version check failed', result.stderr)
        self.assertFalse((self.root / 'build/distribution').exists())


if __name__ == '__main__':
    unittest.main()
