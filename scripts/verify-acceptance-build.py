#!/usr/bin/env python3
"""Capture a read-only build snapshot before or after real application testing."""
import argparse
from contextlib import contextmanager
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from acceptance_build import (_json_digest, checked_image_digest, detach_image,
                              verify_installation)
from version import VERSION_PATTERN

ROOT = Path(__file__).resolve().parents[1]


@contextmanager
def mounted_app(image):
    mount = Path(tempfile.mkdtemp(prefix='qingtype-acceptance-'))
    attached = False
    try:
        subprocess.run(['/usr/bin/hdiutil', 'attach', '-quiet', '-nobrowse', '-readonly',
                        '-mountpoint', str(mount), str(image)], check=True)
        attached = mount.is_mount()
        if not attached: raise ValueError('DMG was not attached at the isolated verification mount')
        yield mount / '清言.app'
    finally:
        if attached:
            detach_image(mount)
            mount.rmdir()
        else:
            try: mount.rmdir()
            except OSError: pass  # Never recursively delete an uncertain mount.


def signature(app):
    result = subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=60)
    if result.returncode: raise ValueError('Bundle signature structure could not be verified')


def runtime_check(pid, app):
    # Reuse the tested one-shot process query; no observation loop is started.
    spec = importlib.util.spec_from_file_location('qingtype_process_probe', ROOT / 'scripts/monitor-memory.py')
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    try:
        probe = module.DarwinServiceProbe(pid, app)
        sample = probe()
    except module.ObservationError as error:
        raise ValueError('Cannot confirm input runtime: ' + str(error)) from None
    headers = subprocess.check_output(['/usr/bin/otool', '-l', str(probe.binary)], text=True, timeout=30)
    values = re.findall(r'^\s*uuid ([0-9A-Fa-f-]{36})\s*$', headers, re.M)
    if len(values) != 1: raise ValueError('Expected one arm64 runtime image UUID')
    return dict(pid=pid, diskImageUUID=values[0], runtimeImageUUID=sample['identity'][0],
                processStart=sample['identity'][1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dmg', type=Path, required=True)
    parser.add_argument('--expected-commit', required=True, help='full immutable source commit; VERSION is read from this commit')
    parser.add_argument('--pid', type=int, required=True, help='one confirmed running QingType service')
    parser.add_argument('--installed-app', type=Path, default=Path.home() / 'Applications/清言.app')
    parser.add_argument('--installed-input', type=Path, default=Path.home() / 'Library/Input Methods/QingType.app')
    parser.add_argument('--output', type=Path, required=True, help='new snapshot file; existing files are never overwritten')
    args = parser.parse_args()
    try:
        if not re.fullmatch('[0-9a-f]{40}', args.expected_commit) or args.pid <= 0:
            raise ValueError('A full source commit and a valid service PID are required')
        if args.output.exists() or args.output.is_symlink(): raise ValueError('Snapshot already exists; choose a new output file')
        for protected in [args.installed_app, args.installed_input, Path.home() / 'Library/QingType', Path.home() / 'Library/Rime']:
            if protected.resolve() == args.output.resolve() or protected.resolve() in args.output.resolve().parents:
                raise ValueError('Snapshots must be outside application bundles and input-method data')
        version = subprocess.check_output(['git', 'show', args.expected_commit + ':VERSION'], cwd=ROOT, text=True).removesuffix('\n')
        if not re.fullmatch(VERSION_PATTERN, version): raise ValueError('Selected source has an invalid VERSION')
        image = args.dmg.resolve()
        digest = checked_image_digest(image)
        with mounted_app(image) as package:
            report = verify_installation(package, args.installed_app, args.installed_input,
                expected_commit=args.expected_commit, expected_version=version, verify_signature=signature,
                verify_runtime=lambda app: runtime_check(args.pid, app))
        if checked_image_digest(image) != digest: raise ValueError('DMG changed during verification')
        report.update(dmgName=image.name, dmgSHA256=digest,
                      checkedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      manifestFormat='sha256-paths-types-modes-links-content-v1')
        report['artifactId'] = _json_digest({k: report[k] for k in ['dmgSHA256', 'version', 'sourceCommit',
            'buildInfoSHA256', 'packageAppContentSHA256', 'packageInputContentSHA256']})
        report['snapshotId'] = _json_digest(report)
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as target:
            json.dump(report, target, indent=2, allow_nan=False); target.write('\n')
        print(json.dumps(report, allow_nan=False))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Acceptance build verification failed: ' + str(error), file=sys.stderr)
        return 1
    except Exception as error:
        # Process-query failures must also fail closed, never emit a PASS snapshot.
        print('Acceptance build verification unavailable: ' + type(error).__name__, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
