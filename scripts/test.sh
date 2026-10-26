#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
yaml_build_dir=$(swift build --package-path dependencies -c release --show-bin-path)
yaml_flags=(-I "$yaml_build_dir" -I "$yaml_build_dir/Modules" -I dependencies/.build/checkouts/Yams/Sources/CYaml/include -L "$yaml_build_dir" -lQingTypeYAML)
swiftc -parse-as-library -swift-version 5 shared/*.swift tests/SettingsSafetyTests.swift "${yaml_flags[@]}" -o build/settings-tests
build/settings-tests
swiftc -parse-as-library -swift-version 5 shared/*.swift tests/ContentTests.swift "${yaml_flags[@]}" -o build/content-tests
swiftc -parse-as-library -swift-version 5 shared/*.swift tests/PersonalDictionaryTests.swift "${yaml_flags[@]}" -o build/personal-dictionary-tests
build/personal-dictionary-tests
build/content-tests
build/QingType.app/Contents/MacOS/QingType --engine-smoke-test
build/QingType.app/Contents/MacOS/QingType --personal-dictionary-engine-test
build/QingType.app/Contents/MacOS/QingType --candidate-ui-test
python3 tests/InputSourceCacheTests.py
build/QingType.app/Contents/MacOS/QingType --status > build/input-source-status.json
python3 - <<'PY'
from pathlib import Path
import plistlib
import json
app = Path('build/QingType.app/Contents')
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'org.qingtype.inputmethod.QingType'
assert info['InputMethodConnectionName'] == info['CFBundleIdentifier'] + '_Connection'
assert info['InputMethodServerControllerClass'] == 'QingType.QingTypeInputController', info
assert not any(key.startswith('SU') for key in info)
assert (app / 'Applications/QingType Settings.app/Contents/MacOS/QingTypeSettings').is_file()
settings_info = plistlib.loads((app / 'Applications/QingType Settings.app/Contents/Info.plist').read_bytes())
assert settings_info['CFBundleShortVersionString'] == info['CFBundleShortVersionString']
assert json.loads(Path('build/input-source-status.json').read_text())['controllerClassFound']
print('PASS: input source identity, settings bundle, and update isolation')
PY
codesign --verify --deep --strict build/QingType.app
