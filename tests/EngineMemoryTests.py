import json
from pathlib import Path
import subprocess
import unittest


class EngineMemoryTests(unittest.TestCase):
    binary = Path(__file__).resolve().parents[1] / 'build/QingType.app/Contents/MacOS/QingType'

    @classmethod
    def setUpClass(cls):
        result = subprocess.run([str(cls.binary), '--engine-stress-test', '100', '--minimum-seconds', '0.3'],
                                capture_output=True, text=True, timeout=90, check=True)
        cls.report = json.loads(result.stdout[result.stdout.index('{'):])

    def test_records_elapsed_time_and_memory_series(self):
        r = self.report
        self.assertEqual(r['formatVersion'], 2)
        self.assertGreaterEqual(r['elapsedSeconds'], 0.3)
        self.assertGreaterEqual(len(r['memorySamples']), 2)
        self.assertGreater(r['memorySamples'][-1]['elapsedSeconds'], r['memorySamples'][0]['elapsedSeconds'])
        self.assertTrue(all(s['residentKB'] > 0 for s in r['memorySamples']))
        self.assertEqual(r['finalResidentKB'], r['memorySamples'][-1]['residentKB'])
        self.assertLess(r['finalResidentKB'] - r['warmResidentKB'], 64 * 1024)

    def test_workload_is_isolated_and_checks_commit_edit_and_cancel(self):
        r = self.report
        self.assertTrue(r['dataIsolated'])
        self.assertFalse(r['hostKeyboardEvents'])
        self.assertFalse(r['optionalModelLoaded'])
        self.assertFalse(r['realApplicationInputVerified'])
        for key in ['verifiedCommits', 'editedCompositions', 'cancelledCompositions']:
            self.assertGreater(r[key], 0)

    def test_latency_and_memory_recording_are_bounded(self):
        self.assertLessEqual(self.report['latencySampleCount'], 8192)
        self.assertLessEqual(len(self.report['memorySamples']), 1024)
        self.assertGreater(self.report['averageEngineAndLayoutMS'], 0)

    def test_invalid_duration_is_rejected(self):
        for duration in ['-1', 'nan', 'inf', '601', 'bad']:
            with self.subTest(duration=duration):
                result = subprocess.run([str(self.binary), '--engine-stress-test', '100', '--minimum-seconds', duration],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
