#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
yaml_flags=(-I dependencies/.build/release -I dependencies/.build/checkouts/Yams/Sources/CYaml/include -L dependencies/.build/release -lQingTypeYAML)
swiftc -parse-as-library -swift-version 5 shared/*.swift tests/SettingsSafetyTests.swift "${yaml_flags[@]}" -o build/settings-tests
build/settings-tests
swiftc -parse-as-library -swift-version 5 shared/*.swift tests/ContentTests.swift "${yaml_flags[@]}" -o build/content-tests
build/content-tests
build/QingType.app/Contents/MacOS/QingType --engine-smoke-test
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
assert info['InputMethodConnectionName'] == 'QingType_Connection'
assert info['InputMethodServerControllerClass'] == 'QingType.QingTypeInputController', info
assert not any(key.startswith('SU') for key in info)
assert (app / 'Applications/QingType Settings.app/Contents/MacOS/QingTypeSettings').is_file()
assert json.loads(Path('build/input-source-status.json').read_text())['controllerClassFound']
print('PASS: input source identity, settings bundle, and update isolation')
PY
codesign --verify --deep --strict build/QingType.app
