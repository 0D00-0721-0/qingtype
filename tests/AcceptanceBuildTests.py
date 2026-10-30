import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from acceptance_build import (verify_installation, tree_digest, require_runtime_uuid,
                              distribution_image, checked_image_digest, detach_image)
from bundle_identity import check_bundle_identity


class AcceptanceBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='qingtype-acceptance-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / '发行包/清言.app'
        self.app = self.root / 'Applications/清言.app'
        self.input = self.root / 'Input Methods/QingType.app'
        self.record = dict(format=1, sourceCommit='a' * 40, workingTreeClean=True,
                           architecture='arm64', minimumMacOS='14.0', explicitRuntimeOverride=False,
                           sourceRepository='https://github.com/0D00-0721-0/qingtype')
        payload = self.package / 'Contents/Resources/InputMethod/QingType.app'
        self.make_bundle(self.package, 'org.qingtype.app', 'QingTypeSettings')
        self.make_bundle(payload, 'org.qingtype.inputmethod.QingType', 'QingType')
        self.make_bundle(payload / 'Contents/Applications/QingType Settings.app', 'org.qingtype.settings', 'QingTypeSettings')
        shutil.copytree(self.package, self.app, symlinks=True)
        shutil.copytree(payload, self.input, symlinks=True)

    def make_bundle(self, bundle, identifier, executable):
        resources = bundle / 'Contents/Resources'
        resources.mkdir(parents=True)
        (resources / 'BuildInfo.json').write_text(json.dumps(self.record))
        (resources / '数据.txt').write_text('synthetic fixture')
        binary = bundle / 'Contents/MacOS' / executable
        binary.parent.mkdir()
        binary.write_bytes(b'synthetic executable')
        binary.chmod(0o755)
        info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable,
                    CFBundleVersion='1.2.3', CFBundleShortVersionString='1.2.3', LSMinimumSystemVersion='14.0')
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))

    def verify(self, signature=lambda app: None, runtime=None):
        return verify_installation(self.package, self.app, self.input,
          expected_commit='a' * 40, expected_version='1.2.3', verify_signature=signature,
          verify_runtime=runtime or (lambda app: self.runtime_identity()))

    def runtime_identity(self, **changes):
        return dict(dict(pid=123, processStart=456, diskImageUUID='1' * 32,
                         runtimeImageUUID='1' * 32), **changes)

    def test_exact_copy_covers_all_eight_records_and_claims_no_input_acceptance(self):
        report = self.verify()
        self.assertEqual(report['bundleRecordCount'], 8)
        self.assertEqual(report['packageAppContentSHA256'], report['installedAppContentSHA256'])
        self.assertEqual(report['packageInputContentSHA256'], report['installedInputContentSHA256'])
        self.assertFalse(report['inputAcceptanceVerified'])
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_identical_version_and_buildinfo_cannot_hide_changed_bytes(self):
        (self.input / 'Contents/MacOS/QingType').write_bytes(b'another executable')
        check_bundle_identity([self.package, self.app, self.input])  # Old metadata check passes.
        with self.assertRaisesRegex(ValueError, 'content'):
            self.verify()

    def test_missing_and_leftover_files_are_rejected(self):
        file = self.input / 'Contents/Resources/数据.txt'
        saved = file.read_bytes(); file.unlink()
        with self.assertRaisesRegex(ValueError, 'content'):
            self.verify()
        file.write_bytes(saved)
        (self.app / 'Contents/obsolete-resource').write_bytes(b'old')
        with self.assertRaisesRegex(ValueError, 'content'):
            self.verify()

    def test_executable_permissions_are_compared(self):
        (self.input / 'Contents/MacOS/QingType').chmod(0o644)
        with self.assertRaises(ValueError):
            self.verify()

    def test_internal_links_are_supported_but_escape_and_missing_targets_fail(self):
        a = self.root / 'links-a'; a.mkdir()
        (a / 'regular').write_bytes(b'safe')
        (a / 'alias').symlink_to('regular')
        b = self.root / 'links-b'; shutil.copytree(a, b, symlinks=True)
        self.assertEqual(tree_digest(a), tree_digest(b))
        (b / 'alias').unlink(); (b / 'alias').symlink_to('../outside')
        (self.root / 'outside').write_bytes(b'outside')
        with self.assertRaises(ValueError): tree_digest(b)
        (b / 'alias').unlink(); (b / 'alias').symlink_to('absent')
        with self.assertRaises(ValueError): tree_digest(b)

    def test_mixed_nested_builds_and_dirty_sources_are_rejected(self):
        path = self.app / 'Contents/Resources/InputMethod/QingType.app/Contents/Applications/QingType Settings.app/Contents/Resources/BuildInfo.json'
        path.write_text(json.dumps({**self.record, 'sourceCommit': 'b' * 40}))
        with self.assertRaises(ValueError): self.verify()
        path.write_text(json.dumps(self.record))
        self.record['workingTreeClean'] = False
        for path in self.root.rglob('BuildInfo.json'): path.write_text(json.dumps(self.record))
        with self.assertRaises(ValueError): self.verify()

    def test_signature_or_runtime_query_failure_is_not_ignored(self):
        def fail(app): raise ValueError('cannot confirm')
        with self.assertRaisesRegex(ValueError, 'cannot confirm'): self.verify(signature=fail)
        with self.assertRaisesRegex(ValueError, 'cannot confirm'): self.verify(runtime=fail)
        with self.assertRaisesRegex(ValueError, 'Unknown runtime'): self.verify(runtime=lambda app: None)

    def test_process_change_during_verification_invalidates_snapshot(self):
        values = iter([self.runtime_identity(), self.runtime_identity(processStart=789)])
        with self.assertRaisesRegex(ValueError, 'runtime'):
            self.verify(runtime=lambda app: next(values))

    def test_running_image_must_match_disk_uuid_and_unknown_values_fail(self):
        self.assertEqual(require_runtime_uuid('11' * 16, '11111111-1111-1111-1111-111111111111'), '11' * 16)
        for value in [None, '', 'unknown', '22' * 16]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                require_runtime_uuid('11' * 16, value)
        with self.assertRaises(ValueError): require_runtime_uuid('0' * 32, '0' * 32)

    def test_helper_compares_distinct_disk_and_runtime_uuids(self):
        report = self.verify(runtime=lambda app: self.runtime_identity(
            runtimeImageUUID='11111111-1111-1111-1111-111111111111'))
        self.assertEqual(report['runtime'], dict(pid=123, processStart=456, imageUUID='1' * 32))

    def test_helper_rejects_mismatch_even_with_a_legacy_image_uuid(self):
        value = self.runtime_identity(runtimeImageUUID='2' * 32, imageUUID='1' * 32)
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.verify(runtime=lambda app: value)

    def test_helper_requires_both_uuid_fields(self):
        for field in ['diskImageUUID', 'runtimeImageUUID']:
            value = self.runtime_identity(); del value[field]
            value['imageUUID'] = '1' * 32
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(runtime=lambda app: value)
        with self.assertRaises(ValueError):
            self.verify(runtime=lambda app: dict(pid=123, processStart=456, imageUUID='1' * 32))

    def test_helper_rejects_invalid_and_zero_uuids_on_either_side(self):
        for field in ['diskImageUUID', 'runtimeImageUUID']:
            for invalid in [None, '', 'unknown', 'invalid-uuid', '0' * 32,
                            '00000000-0000-0000-0000-000000000000', 11111111111111111111111111111111, True]:
                value = self.runtime_identity(**{field: invalid})
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    self.verify(runtime=lambda app: value)

    def test_helper_rejects_invalid_process_identity(self):
        for field in ['pid', 'processStart']:
            for invalid in [None, 0, -1, True, False, '123', 1.5, float('inf')]:
                value = self.runtime_identity(**{field: invalid})
                with self.subTest(field=field, value=invalid), self.assertRaisesRegex(ValueError, 'runtime identity'):
                    self.verify(runtime=lambda app: value)

    def test_helper_checks_runtime_uuid_again_after_content_verification(self):
        values = iter([self.runtime_identity(), self.runtime_identity(
            runtimeImageUUID='2' * 32, imageUUID='1' * 32)])
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.verify(runtime=lambda app: next(values))

    def test_rejects_wrong_bundle_identity_and_version(self):
        path = self.input / 'Contents/Info.plist'; value = plistlib.loads(path.read_bytes())
        for change in [dict(CFBundleIdentifier='unrelated.app'), dict(CFBundleVersion='1.2.2')]:
            path.write_bytes(plistlib.dumps({**value, **change}))
            with self.assertRaises(ValueError): self.verify()

    def test_distribution_refuses_stale_images_and_verifies_sidecar(self):
        directory = self.root / 'distribution'; directory.mkdir()
        image = directory / 'QingType-1.2.3-arm64.dmg'; image.write_bytes(b'synthetic image')
        digest = hashlib.sha256(image.read_bytes()).hexdigest()
        image.with_suffix('.dmg.sha256').write_text(digest + '  ' + image.name + '\n')
        self.assertEqual(distribution_image(directory, '1.2.3'), image)
        self.assertEqual(checked_image_digest(image), digest)
        (directory / 'QingType-1.2.2-arm64.dmg').write_bytes(b'old')
        with self.assertRaisesRegex(ValueError, 'one'): distribution_image(directory, '1.2.3')
        image.write_bytes(b'modified')
        with self.assertRaises(ValueError): checked_image_digest(image)

    def test_detach_retries_busy_only_and_never_forces(self):
        from types import SimpleNamespace
        import subprocess
        calls, sleeps = [], []
        values = iter([16, 16, 0])
        def run(command):
            calls.append(command)
            return SimpleNamespace(returncode=next(values))
        detach_image('/synthetic/mount', run=run, sleep=sleeps.append)
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [0.5, 0.5])
        self.assertTrue(all('force' not in ' '.join(command) for command in calls))
        with self.assertRaises(subprocess.CalledProcessError):
            detach_image('/synthetic/mount', run=lambda command: SimpleNamespace(returncode=5), sleep=lambda _: self.fail('unexpected retry'))

    def test_changes_during_content_capture_are_rejected(self):
        from unittest.mock import patch
        import acceptance_build
        original = acceptance_build.file_digest
        def mutate(path):
            result = original(path)
            (self.input / 'Contents/late-resource').write_bytes(b'changed during check')
            return result
        with patch.object(acceptance_build, 'file_digest', side_effect=mutate):
            with self.assertRaisesRegex(ValueError, 'changed during'):
                tree_digest(self.input)

    def test_cli_does_not_overwrite_an_existing_snapshot(self):
        import subprocess
        snapshot = self.root / 'existing.json'; snapshot.write_bytes(b'previous result')
        command = [sys.executable, str(Path(__file__).resolve().parents[1] / 'scripts/verify-acceptance-build.py'),
                   '--dmg', str(self.root / 'absent.dmg'), '--expected-commit', 'a' * 40,
                   '--pid', '1', '--output', str(snapshot)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot.read_bytes(), b'previous result')


if __name__ == '__main__':
    unittest.main()
