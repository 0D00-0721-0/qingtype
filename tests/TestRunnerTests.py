"""The required integration fixture must never be silently skipped in CI."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class TestRunnerTests(unittest.TestCase):
    def test_required_fixture_is_checked_before_build_or_tests(self):
        with tempfile.TemporaryDirectory(prefix="qingtype-runner-test-") as directory:
            for fixture in (None, directory):
                env = os.environ.copy()
                env['QINGTYPE_REQUIRE_RIME_ICE_TEST'] = '1'
                env.pop('QINGTYPE_RIME_ICE_TEST_PACKAGE', None)
                if fixture is not None:
                    env['QINGTYPE_RIME_ICE_TEST_PACKAGE'] = fixture
                result = subprocess.run(['bash', str(ROOT / 'scripts/test.sh')], cwd=ROOT,
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('required Rime Ice test fixture', result.stderr)
                self.assertNotIn('content and migration checks', result.stdout)


if __name__ == '__main__':
    unittest.main()
