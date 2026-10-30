#!/usr/bin/env python3
"""Read-only sampling of one installed QingType process; never collects input."""
import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import sys
import time


class ObservationError(Exception):
    pass


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write('\n')
    os.replace(temporary, path)


def observe(probe, output, *, duration, interval, metadata=None,
            clock=time.monotonic, wall_clock=time.time, sleep=time.sleep):
    if not all(math.isfinite(v) and v > 0 for v in [duration, interval]) or duration > 86400:
        raise ValueError('duration and interval must be positive; duration is at most 24 hours')
    if interval < duration / 9999:
        raise ValueError('an observation is limited to 10000 samples')
    output = Path(output)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    allowed = {'sourceCommit', 'workingTreeClean', 'architecture', 'version', 'executableSHA256', 'pid', 'observerScriptSHA256'}
    report = dict(format='org.qingtype.memory-observation', formatVersion=1,
                  startedUTC=datetime.datetime.fromtimestamp(wall_clock(), datetime.timezone.utc).isoformat(),
                  requestedSeconds=duration, intervalSeconds=interval,
                  build={k: v for k, v in (metadata or {}).items() if k in allowed},
                  inputActivityVerified=False, inputContentCollected=False,
                  hostKeyboardEventsInjected=False, memoryVerdict='not_assessed')
    write_json(output / 'metadata.json', report)
    samples = []
    start = clock()
    identity = None
    maximum_gap = 0.0
    reason = 'duration_not_reached'
    fd = os.open(output / 'samples.jsonl', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', buffering=1) as journal:
        try:
            while True:
                now, wall = clock(), wall_clock()
                sample = probe()
                fields = ['residentBytes', 'physicalFootprintBytes']
                if any(type(sample.get(k)) is not int or sample[k] < 0 for k in fields) or not all(sample[k] > 0 for k in fields[:2]):
                    raise ObservationError('invalid_memory_sample')
                if not sample.get('identity'):
                    raise ObservationError('missing_process_identity')
                if identity is None:
                    identity = sample['identity']
                elif identity != sample['identity']:
                    raise ObservationError('process_identity_changed')
                if samples:
                    gap = max(now - start - samples[-1]['elapsedSeconds'], wall - samples[-1]['wallTime'])
                    maximum_gap = max(maximum_gap, gap)
                    if gap > max(interval * 3, interval + 5):
                        raise ObservationError('sampling_gap')
                point = dict(elapsedSeconds=now - start, wallTime=wall, **{k: sample[k] for k in fields})
                journal.write(json.dumps(point, allow_nan=False) + '\n')
                samples.append(point)
                if now - start >= duration:
                    reason = 'completed'
                    break
                sleep(min(interval, duration - (now - start)))
        except ObservationError as error:
            reason = str(error)
        except KeyboardInterrupt:
            reason = 'interrupted'
    def statistics(key):
        if not samples:
            return None
        values = [s[key] for s in samples]
        return dict(start=values[0], end=values[-1], min=min(values), max=max(values), delta=values[-1] - values[0])
    report.update(complete=reason == 'completed', reason=reason, sampleCount=len(samples),
                  elapsedSeconds=clock() - start, maximumGapSeconds=maximum_gap,
                  residentBytes=statistics('residentBytes'), physicalFootprintBytes=statistics('physicalFootprintBytes'))
    write_json(output / 'summary.json', report)
    return report


class RUsageInfoV0(ctypes.Structure):
    # Xcode SDK sys/resource.h, RUSAGE_INFO_V0. Memory fields are bytes;
    # CPU fields are Mach absolute ticks and are deliberately not reported.
    _fields_ = [('uuid', ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in [
        'user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins',
        'wired_size', 'resident_size', 'phys_footprint', 'proc_start_abstime', 'proc_exit_abstime']]


class DarwinServiceProbe:
    def __init__(self, pid, app):
        if sys.platform != 'darwin' or pid <= 0:
            raise ObservationError('requires_macos_and_valid_pid')
        self.pid = pid
        self.app = Path(app).resolve()
        self.binary = self.app / 'Contents/MacOS/QingType'
        self.info_path = self.app / 'Contents/Info.plist'
        self.build_path = self.app / 'Contents/Resources/BuildInfo.json'
        try:
            info = plistlib.loads(self.info_path.read_bytes())
            build = json.loads(self.build_path.read_text())
            if info.get('CFBundleIdentifier') != 'org.qingtype.inputmethod.QingType' or info.get('CFBundleExecutable') != 'QingType':
                raise ObservationError('unexpected_application_identity')
            if not isinstance(build.get('sourceCommit'), str) or not re.fullmatch('[0-9a-f]{40}', build['sourceCommit']):
                raise ObservationError('unknown_build_identity')
            self.fingerprint = self.file_identity()
            digest = hashlib.sha256()
            with self.binary.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
        except (OSError, ValueError):
            raise ObservationError('cannot_read_build_identity') from None
        self.metadata = {k: build[k] for k in ['sourceCommit', 'workingTreeClean', 'architecture'] if k in build}
        self.metadata.update(pid=pid, version=info.get('CFBundleShortVersionString'), executableSHA256=digest.hexdigest())
        self.lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.lib.proc_pid_rusage.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int

    def file_identity(self):
        return tuple((s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
                     for s in [p.stat() for p in [self.binary, self.info_path, self.build_path]])

    def __call__(self):
        try:
            if self.file_identity() != self.fingerprint:
                raise ObservationError('installed_build_changed')
        except OSError:
            raise ObservationError('installed_build_unavailable') from None
        path = ctypes.create_string_buffer(4096)
        info = RUsageInfoV0()
        if self.lib.proc_pidpath(self.pid, path, len(path)) <= 0 or self.lib.proc_pid_rusage(self.pid, 0, ctypes.byref(info)) != 0:
            raise ObservationError('process_unavailable')
        if os.fsdecode(path.value) != str(self.binary):
            raise ObservationError('unexpected_process_executable')
        if info.proc_exit_abstime or not info.proc_start_abstime:
            raise ObservationError('process_not_running')
        return dict(identity=(bytes(info.uuid).hex(), info.proc_start_abstime),
                    residentBytes=info.resident_size, physicalFootprintBytes=info.phys_footprint)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--app', type=Path, default=Path.home() / 'Library/Input Methods/QingType.app')
    parser.add_argument('--output', type=Path, required=True, help='new private report directory; parent must exist')
    parser.add_argument('--duration-seconds', type=float, default=7200)
    parser.add_argument('--interval-seconds', type=float, default=15)
    args = parser.parse_args()
    for protected in [Path.home() / 'Library/QingType', Path.home() / 'Library/Rime']:
        if protected.resolve() in args.output.resolve().parents or args.output.resolve() == protected.resolve():
            parser.error('reports must be outside input-method user data')
    def terminate(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    try:
        probe = DarwinServiceProbe(args.pid, args.app)
        probe.metadata['observerScriptSHA256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        result = observe(probe, args.output, duration=args.duration_seconds, interval=args.interval_seconds, metadata=probe.metadata)
    except (ObservationError, OSError, ValueError) as error:
        print('Memory observation could not start: ' + (str(error) if isinstance(error, ObservationError) else type(error).__name__), file=sys.stderr)
        return 1
    print(json.dumps(result, allow_nan=False))
    return 0 if result['complete'] else 1


if __name__ == '__main__':
    sys.exit(main())
