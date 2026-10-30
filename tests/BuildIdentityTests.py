import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from bundle_identity import check_bundle_identity


class BuildIdentityTests(unittest.TestCase):
    def test_same_product_version_does_not_hide_mixed_builds(self):
        with tempfile.TemporaryDirectory(prefix='qingtype-identity-') as directory:
            bundles = [Path(directory) / name for name in ('app', 'service', 'settings')]
            record = {'sourceCommit': 'a' * 40, 'workingTreeClean': True, 'architecture': 'arm64'}
            for bundle in bundles:
                resources = bundle / 'Contents/Resources'
                resources.mkdir(parents=True)
                (resources / 'BuildInfo.json').write_text(json.dumps(record))
            self.assertEqual(check_bundle_identity(bundles), record)
            check_bundle_identity(bundles, require_clean=True, expected_commit='a' * 40)
            for changed in ({**record, 'sourceCommit': 'b' * 40},
                            {**record, 'workingTreeClean': False},
                            {**record, 'architecture': 'x86_64'}):
                (bundles[-1] / 'Contents/Resources/BuildInfo.json').write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    check_bundle_identity(bundles)
            for bundle in bundles:
                (bundle / 'Contents/Resources/BuildInfo.json').write_text(json.dumps({**record, 'workingTreeClean': False}))
            check_bundle_identity(bundles)  # Local development packages remain inspectable.
            with self.assertRaises(ValueError):
                check_bundle_identity(bundles, require_clean=True)
            with self.assertRaises(ValueError):
                check_bundle_identity(bundles, expected_commit='b' * 40)


if __name__ == '__main__':
    unittest.main()
