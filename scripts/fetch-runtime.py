#!/usr/bin/env python3
"""Extract a hash-pinned upstream runtime; never install Squirrel on the host."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

project = Path(__file__).resolve().parent.parent
lock = json.loads((project / 'dependencies/runtime.lock.json').read_text())
cache = project / 'build/runtime' / lock['version']
cache.mkdir(parents=True, exist_ok=True)
archive = cache / lock['filename']

def valid_archive(path):
    if not path.is_file() or path.stat().st_size != lock['size']:
        return False
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest() == lock['sha256']

if not valid_archive(archive):
    stage = archive.with_suffix('.download')
    print('下载固定版本的 Rime 运行库…', file=sys.stderr)
    try:
        subprocess.run(['/usr/bin/curl', '--fail', '--location', '--retry', '3',
                        '--connect-timeout', '30', '--max-time', '600',
                        '--output', str(stage), lock['url']], check=True, stdout=sys.stderr)
        if not valid_archive(stage):
            raise RuntimeError('运行库大小或 SHA-256 校验失败')
        stage.replace(archive)
    finally:
        stage.unlink(missing_ok=True)

expanded = cache / 'expanded'
marker = cache / 'archive.sha256'
apps = list(expanded.rglob('Squirrel.app')) if expanded.exists() else []
if not marker.exists() or marker.read_text() != lock['sha256'] or len(apps) != 1:
    shutil.rmtree(expanded, ignore_errors=True)
    subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(archive), str(expanded)],
                   check=True, stdout=sys.stderr)
    apps = list(expanded.rglob('Squirrel.app'))
    if len(apps) != 1:
        raise RuntimeError('运行库包不包含唯一的 Squirrel.app')
    marker.write_text(lock['sha256'])

runtime = apps[0]
for relative in ['Contents/Frameworks/librime.1.dylib', 'Contents/Frameworks/rime-plugins',
                 'Contents/SharedSupport/luna_pinyin.dict.yaml']:
    if not (runtime / relative).exists():
        raise RuntimeError(f'运行库缺少 {relative}')
print(runtime)
