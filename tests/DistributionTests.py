"""Inspect the actual distributable, including its offline, empty-profile payload."""
from pathlib import Path
import plistlib
import subprocess
import hashlib
import time
import sys
import os

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from version import check_bundles, product_version

version = product_version()

def detach_test_image(mount):
    # Spotlight or other system readers may briefly retain a newly exercised
    # read-only image after the test process exits (observed on macOS 14 CI).
    # Retry only EBUSY, never force-detach a disk or hide another cleanup error.
    command = ['/usr/bin/hdiutil', 'detach', '-quiet', str(mount)]
    for attempt in range(5):
        result = subprocess.run(command)
        if result.returncode == 0:
            return
        if result.returncode != 16 or attempt == 4:
            raise subprocess.CalledProcessError(result.returncode, command)
        time.sleep(0.5)

distribution = Path(os.environ.get('QINGTYPE_DISTRIBUTION_DIR', 'build/distribution'))
app = distribution / '清言.app'
payload = app / 'Contents/Resources/InputMethod/QingType.app'
settings = payload / 'Contents/Applications/QingType Settings.app'
check_bundles(version, [app, payload, settings])

def info(path):
    return plistlib.loads((path / 'Contents/Info.plist').read_bytes())

outer, inner = info(app), info(payload)
import json
for bundle in [app, payload]:
    resources = bundle / 'Contents/Resources'
    records = json.loads((resources / 'components.lock.json').read_text())['sourceNoticeRecords']
    for record in records:
        notice = resources / 'Licenses' / Path(record['licenseFile']).name
        assert hashlib.sha256(notice.read_bytes()).hexdigest() == record['sha256']
    provenance = json.loads((resources / 'BuildInfo.json').read_text())
    assert len(provenance['sourceCommit']) == 40 and provenance['noticeCount'] == len(records)
    assert not provenance['explicitRuntimeOverride'], 'Public artifacts must use the pinned runtime'
    assert '/Users/' not in json.dumps(provenance), 'Build records must not expose developer paths'
assert outer['CFBundleIdentifier'] == 'org.qingtype.app'
assert inner['CFBundleIdentifier'] == 'org.qingtype.inputmethod.QingType'
assert outer['CFBundleShortVersionString'] == inner['CFBundleShortVersionString']
assert outer['LSMinimumSystemVersion'] == inner['LSMinimumSystemVersion'] == '14.0'
assert inner['InputMethodConnectionName'] == inner['CFBundleIdentifier'] + '_Connection'
assert not list(app.rglob('*.gram')), 'Optional models must not be bundled'
assert not list(app.rglob('*.userdb')), 'User learning must not be bundled'
assert not list(app.rglob('settings.json')), 'Personal configuration must not be bundled'
assert not list(app.rglob('rime_ice.schema.yaml')), 'Rime Ice is optional'
for relative in ['Frameworks/librime.1.dylib', 'Frameworks/rime-plugins',
                 'SharedSupport/luna_pinyin.dict.yaml', 'SharedSupport/qingtype_double_pinyin.schema.yaml',
                 'Applications/QingType Settings.app', 'Resources/LICENSE.txt', 'Resources/THIRD_PARTY.md']:
    assert (payload / 'Contents' / relative).exists(), relative
for binary in [app / 'Contents/MacOS/QingTypeSettings', payload / 'Contents/MacOS/QingType']:
    headers = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
    assert 'minos 14.0' in headers, 'Info.plist must match the compiled deployment target'
    links = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True)
    assert '/Library/Input Methods/Squirrel.app' not in links
    assert '/Users/yuyiyang/' not in '\n'.join(links.splitlines()[1:])
expected_image = distribution / f'QingType-{version}-arm64.dmg'
images = list(distribution.glob('QingType-*.dmg'))
assert expected_image in images and all(p.with_suffix('.dmg.sha256').exists() for p in images)
for image in images:
    digest, name = image.with_suffix('.dmg.sha256').read_text().strip().split(maxsplit=1)
    assert name == image.name and hashlib.sha256(image.read_bytes()).hexdigest() == digest
    mount = Path('build/dmg-verification').resolve()
    mount.mkdir(exist_ok=True)
    subprocess.run(['/usr/bin/hdiutil', 'attach', '-quiet', '-nobrowse', '-readonly', '-mountpoint', str(mount), str(image)], check=True)
    try:
        mounted = mount / '清言.app'
        if image == expected_image:
            mounted_payload = mounted / 'Contents/Resources/InputMethod/QingType.app'
            check_bundles(version, [mounted, mounted_payload, mounted_payload / 'Contents/Applications/QingType Settings.app'])
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(mounted)], check=True)
        binary = mounted / 'Contents/Resources/InputMethod/QingType.app/Contents/MacOS/QingType'
        subprocess.run([str(binary), '--factory-engine-test'], check=True)
    finally:
        detach_test_image(mount)
print('PASS: distribution identity, minimum OS, bundled runtime, optional-data exclusion and packaged offline engine')
