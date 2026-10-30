"""Content and provenance checks for a fixed QingType acceptance artifact."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time
import uuid

from bundle_identity import check_bundle_identity
from version import check_bundles, VERSION_PATTERN


def _json_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':')).encode()).hexdigest()


def file_digest(path):
    path = Path(path)
    before = path.stat()
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    after = path.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError('File changed during hashing')
    return digest.hexdigest()


def _inventory(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError('Bundle root must be a real directory')
    resolved = root.resolve()
    result = {}
    def visit(path, relative):
        info = path.lstat()
        identity = (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns)
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            try:
                inside = not os.path.isabs(target) and path.resolve(strict=True).is_relative_to(resolved)
            except (OSError, RuntimeError):
                inside = False
            if not inside: raise ValueError('Bundle contains an escaping or missing link: ' + relative)
            item = dict(kind='link', target=target)
        elif stat.S_ISDIR(info.st_mode):
            item = dict(kind='directory', mode=stat.S_IMODE(info.st_mode))
        elif stat.S_ISREG(info.st_mode):
            item = dict(kind='file', mode=stat.S_IMODE(info.st_mode), size=info.st_size)
        else:
            raise ValueError('Bundle contains an unsupported file: ' + relative)
        result[relative] = (identity, item)
        if item['kind'] == 'directory':
            for child in sorted(path.iterdir()):
                visit(child, child.relative_to(root).as_posix())
    visit(root, '.')
    return result


def tree_digest(root):
    root = Path(root)
    before = _inventory(root)
    entries = {}
    for relative, (_, item) in before.items():
        entry = dict(item)
        if entry['kind'] == 'file': entry['sha256'] = file_digest(root / relative)
        entries[relative] = entry
    if before != _inventory(root): raise ValueError('Bundle changed during content verification')
    return _json_digest(dict(format=1, entries=entries))


def require_runtime_uuid(expected, observed):
    if not isinstance(expected, str) or not isinstance(observed, str):
        raise ValueError('Unknown runtime image UUID')
    try:
        a, b = uuid.UUID(expected).hex, uuid.UUID(observed).hex
    except (ValueError, TypeError, AttributeError):
        raise ValueError('Unknown runtime image UUID') from None
    if a == '0' * 32 or b == '0' * 32: raise ValueError('Unknown runtime image UUID')
    if a != b: raise ValueError('Running image UUID does not match installed executable')
    return a


def distribution_image(directory, version):
    if not re.fullmatch(VERSION_PATTERN, version): raise ValueError('Invalid artifact version')
    directory = Path(directory)
    expected = directory / ('QingType-' + version + '-arm64.dmg')
    if sorted(directory.glob('QingType-*.dmg')) != [expected]:
        raise ValueError('Use a directory with exactly one current arm64 DMG; keep older artifacts separately')
    if not expected.with_suffix('.dmg.sha256').is_file(): raise ValueError('Missing DMG checksum')
    return expected


def checked_image_digest(image):
    image = Path(image)
    sidecar = image.with_suffix('.dmg.sha256')
    if image.is_symlink() or sidecar.is_symlink() or sidecar.stat().st_size > 4096:
        raise ValueError('Invalid DMG or checksum file')
    parts = sidecar.read_text().strip().split(maxsplit=1)
    if len(parts) != 2 or not re.fullmatch('[0-9a-f]{64}', parts[0]) or parts[1] != image.name:
        raise ValueError('Checksum must name the selected DMG')
    digest = file_digest(image)
    if digest != parts[0]: raise ValueError('DMG checksum mismatch')
    return digest


def detach_image(mount, *, run=subprocess.run, sleep=time.sleep):
    command = ['/usr/bin/hdiutil', 'detach', '-quiet', str(mount)]
    for attempt in range(5):
        result = run(command)
        if result.returncode == 0: return
        if result.returncode != 16 or attempt == 4:
            raise subprocess.CalledProcessError(result.returncode, command)
        sleep(0.5)


def verify_installation(package, app, input_service, *, expected_commit, expected_version,
                        verify_signature, verify_runtime):
    """Verify bundles and compare diskImageUUID/runtimeImageUUID from the probe.

    verify_runtime must return both independently obtained UUIDs plus positive
    integer pid/processStart. The public report retains its normalized imageUUID.
    """
    if not isinstance(expected_commit, str) or not re.fullmatch('[0-9a-f]{40}', expected_commit):
        raise ValueError('A fixed full source commit is required')
    if not isinstance(expected_version, str) or not re.fullmatch(VERSION_PATTERN, expected_version):
        raise ValueError('A valid fixed product version is required')
    package, app, input_service = map(Path, [package, app, input_service])
    package_input = package / 'Contents/Resources/InputMethod/QingType.app'
    app_input = app / 'Contents/Resources/InputMethod/QingType.app'
    settings = 'Contents/Applications/QingType Settings.app'
    roles = [(package, 'org.qingtype.app', 'QingTypeSettings'),
             (package_input, 'org.qingtype.inputmethod.QingType', 'QingType'),
             (package_input / settings, 'org.qingtype.settings', 'QingTypeSettings'),
             (app, 'org.qingtype.app', 'QingTypeSettings'),
             (app_input, 'org.qingtype.inputmethod.QingType', 'QingType'),
             (app_input / settings, 'org.qingtype.settings', 'QingTypeSettings'),
             (input_service, 'org.qingtype.inputmethod.QingType', 'QingType'),
             (input_service / settings, 'org.qingtype.settings', 'QingTypeSettings')]
    bundles = [p for p, _, _ in roles]
    record = check_bundle_identity(bundles, require_clean=True, expected_commit=expected_commit)
    if (record.get('format') != 1 or record.get('architecture') != 'arm64' or record.get('minimumMacOS') != '14.0'
            or record.get('explicitRuntimeOverride') is not False
            or record.get('sourceRepository') != 'https://github.com/0D00-0721-0/qingtype'):
        raise ValueError('Unknown or unsupported acceptance build provenance')
    check_bundles(expected_version, bundles)
    for path, identifier, executable in roles:
        info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != identifier or info.get('CFBundleExecutable') != executable:
            raise ValueError('Unexpected bundle identity')
    for root in [package, app, input_service]: verify_signature(root)
    def runtime():
        value = verify_runtime(input_service)
        if not isinstance(value, dict) or any(type(value.get(k)) is not int or value[k] <= 0 for k in ['pid', 'processStart']):
            raise ValueError('Unknown runtime identity')
        return dict(pid=value['pid'], processStart=value['processStart'],
                    imageUUID=require_runtime_uuid(value.get('diskImageUUID'), value.get('runtimeImageUUID')))
    before = runtime()
    package_hash, installed_hash = tree_digest(package), tree_digest(app)
    payload_hash, input_hash = tree_digest(package_input), tree_digest(input_service)
    if package_hash != installed_hash or payload_hash != input_hash:
        raise ValueError('Installed bundle content differs from the fixed package')
    if runtime() != before: raise ValueError('Input runtime changed during verification')
    if check_bundle_identity(bundles, require_clean=True, expected_commit=expected_commit) != record:
        raise ValueError('Build metadata changed during verification')
    return dict(format='org.qingtype.acceptance-build', formatVersion=1,
                version=expected_version, sourceCommit=expected_commit, architecture='arm64', workingTreeClean=True,
                buildInfoSHA256=_json_digest(record), bundleRecordCount=len(bundles),
                packageAppContentSHA256=package_hash, installedAppContentSHA256=installed_hash,
                packageInputContentSHA256=payload_hash, installedInputContentSHA256=input_hash,
                runtime=before, inputAcceptanceVerified=False)
