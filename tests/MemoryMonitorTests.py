import importlib.util
import ctypes
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('memory_monitor', Path(__file__).resolve().parents[1] / 'scripts/monitor-memory.py')
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class FakeClock:
    def __init__(self):
        self.value = 0.0
    def now(self):
        return self.value
    def sleep(self, seconds):
        self.value += seconds


class MemoryMonitorTests(unittest.TestCase):
    def run_case(self, probe, sleep=None):
        clock = FakeClock()
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / 'record'
            result = monitor.observe(probe, output, duration=2, interval=1,
                                     clock=clock.now, wall_clock=clock.now, sleep=sleep or clock.sleep,
                                     metadata={'sourceCommit': 'a' * 40, 'privatePath': '/private/example'})
            summary = json.loads((output / 'summary.json').read_text())
            samples = [json.loads(line) for line in (output / 'samples.jsonl').read_text().splitlines()]
            self.assertEqual(result, summary)
            self.assertEqual((output.stat().st_mode & 0o777), 0o700)
            self.assertEqual(((output / 'summary.json').stat().st_mode & 0o777), 0o600)
            self.assertNotIn('privatePath', summary['build'])
            return summary, samples

    @staticmethod
    def sample(identity='first', rss=100, footprint=80):
        return dict(identity=identity, residentBytes=rss, physicalFootprintBytes=footprint)

    def test_records_series_and_exact_elapsed_without_claiming_input(self):
        values = iter([self.sample(rss=100), self.sample(rss=120), self.sample(rss=110)])
        result, samples = self.run_case(lambda: next(values))
        self.assertTrue(result['complete'])
        self.assertEqual([s['elapsedSeconds'] for s in samples], [0, 1, 2])
        self.assertEqual(result['residentBytes']['max'], 120)
        self.assertEqual(result['residentBytes']['delta'], 10)
        self.assertFalse(result['inputActivityVerified'])
        self.assertEqual(result['memoryVerdict'], 'not_assessed')

    def test_restart_or_pid_reuse_invalidates_observation(self):
        values = iter([self.sample(), self.sample(identity='replacement')])
        result, samples = self.run_case(lambda: next(values))
        self.assertFalse(result['complete'])
        self.assertEqual(result['reason'], 'process_identity_changed')
        self.assertEqual(len(samples), 1)

    def test_failed_read_does_not_become_zero_memory_or_success(self):
        def fail():
            raise monitor.ObservationError('process_unavailable')
        result, samples = self.run_case(fail)
        self.assertFalse(result['complete'])
        self.assertIsNone(result['residentBytes'])
        self.assertEqual(samples, [])

    def test_unknown_or_invalid_metrics_fail(self):
        for invalid in [None, -1, float('nan'), True]:
            with self.subTest(invalid=invalid):
                result, _ = self.run_case(lambda: self.sample(rss=invalid))
                self.assertFalse(result['complete'])
                self.assertEqual(result['reason'], 'invalid_memory_sample')

    def test_long_gap_is_recorded_and_not_continuous(self):
        clock = FakeClock()
        with tempfile.TemporaryDirectory() as root:
            def gap(seconds):
                clock.value += 20
            result = monitor.observe(self.sample, Path(root) / 'gap', duration=2, interval=1,
                                     clock=clock.now, wall_clock=clock.now, sleep=gap)
            self.assertFalse(result['complete'])
            self.assertEqual(result['reason'], 'sampling_gap')
            self.assertEqual(result['maximumGapSeconds'], 20)

    def test_interruption_preserves_partial_report(self):
        def interrupt(seconds):
            raise KeyboardInterrupt
        result, samples = self.run_case(self.sample, sleep=interrupt)
        self.assertFalse(result['complete'])
        self.assertEqual(result['reason'], 'interrupted')
        self.assertEqual(len(samples), 1)

    def test_refuses_to_overwrite_a_previous_observation(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(FileExistsError):
                monitor.observe(self.sample, Path(root), duration=2, interval=1)

    def test_invalid_timing_is_rejected_before_recording(self):
        for duration, interval in [(0, 1), (-1, 1), (1, 0), (float('inf'), 1), (2, float('nan')), (86400, 0.001)]:
            with tempfile.TemporaryDirectory() as root, self.assertRaises(ValueError):
                monitor.observe(self.sample, Path(root) / 'invalid', duration=duration, interval=interval)

    def test_backend_rejects_another_executable_and_failed_system_query(self):
        class FakeLib:
            def proc_pidpath(self, pid, path, size):
                path.value = b'/another/QingType'
                return 17
            def proc_pid_rusage(self, pid, flavor, pointer):
                info = ctypes.cast(pointer, ctypes.POINTER(monitor.RUsageInfoV0)).contents
                info.proc_start_abstime = 123
                return 0
        probe = monitor.DarwinServiceProbe.__new__(monitor.DarwinServiceProbe)
        probe.pid, probe.binary, probe.lib = 42, Path('/expected/QingType'), FakeLib()
        probe.fingerprint = 'old'
        probe.file_identity = lambda: 'old'
        with self.assertRaisesRegex(monitor.ObservationError, 'unexpected_process_executable'):
            probe()
        probe.lib.proc_pid_rusage = lambda *args: -1
        with self.assertRaisesRegex(monitor.ObservationError, 'process_unavailable'):
            probe()

    def test_installed_build_change_stops_the_probe_before_sampling(self):
        probe = monitor.DarwinServiceProbe.__new__(monitor.DarwinServiceProbe)
        probe.fingerprint = 'old'
        probe.file_identity = lambda: 'new'
        with self.assertRaisesRegex(monitor.ObservationError, 'installed_build_changed'):
            probe()


if __name__ == '__main__':
    unittest.main()
