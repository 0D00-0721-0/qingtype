#!/usr/bin/env python3
"""Copy verified notices and write a profile-free, reproducible source record."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys

project = Path(__file__).resolve().parent.parent
app, settings, runtime = map(Path, sys.argv[1:])
lock = json.loads((project / 'dependencies/components.lock.json').read_text())
for record in lock['sourceNoticeRecords']:
    data = (project / record['licenseFile']).read_bytes()
    if hashlib.sha256(data).hexdigest() != record['sha256']:
        raise RuntimeError('Third-party notice checksum mismatch: ' + record['licenseFile'])

def output(*args):
    return subprocess.check_output(args, cwd=project, text=True).strip()

provenance = {
    'format': 1,
    'sourceRepository': 'https://github.com/0D00-0721-0/qingtype',
    'sourceCommit': output('git', 'rev-parse', 'HEAD'),
    'workingTreeClean': not output('git', 'status', '--porcelain'),
    'architecture': platform.machine(),
    'minimumMacOS': '14.0',
    'swift': output('swiftc', '--version').splitlines()[0],
    'sdkVersion': output('xcrun', '--show-sdk-version'),
    'runtimePackage': json.loads((project / 'dependencies/runtime.lock.json').read_text()),
    'runtimeLibraries': {p.relative_to(runtime).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted((runtime / 'Contents/Frameworks').rglob('*.dylib'))},
    'explicitRuntimeOverride': bool(__import__('os').environ.get('QINGTYPE_RUNTIME_APP')),
    'noticeCount': len(lock['sourceNoticeRecords']),
}
for target in [app, settings]:
    resources = target / 'Contents/Resources'
    shutil.copytree(project / 'licenses', resources / 'Licenses', dirs_exist_ok=True)
    for name in ['components.lock.json', 'runtime.lock.json', 'runtime-files.lock.json']:
        shutil.copy2(project / 'dependencies' / name, resources / name)
    for name in ['LICENSE.txt', 'THIRD_PARTY.md']:
        shutil.copy2(project / name, resources / name)
    (resources / 'BuildInfo.json').write_text(json.dumps(provenance, indent=2) + '\n')
print('Recorded source commit and verified third-party notices:', provenance['noticeCount'])
