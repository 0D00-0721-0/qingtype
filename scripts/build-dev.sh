#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Local development: reuse the user's installed Squirrel runtime and data.
# This script never changes that installation or its user directory.
runtime_app="${QINGTYPE_RUNTIME_APP:-$HOME/Library/Input Methods/Squirrel.app}"
runtime="$runtime_app/Contents"
if [[ ! -f "$runtime/Frameworks/librime.1.dylib" ]]; then
  echo "找不到 Rime 运行库，请设置 QINGTYPE_RUNTIME_APP 为鼠须管应用路径。" >&2
  exit 1
fi
if [[ ! -f librime/src/rime_api.h ]]; then
  git submodule update --init --depth 1 librime
fi

app="$PWD/build/QingType.app"
settings_app="$app/Contents/Applications/QingType Settings.app"
mkdir -p "$app/Contents/"{MacOS,Resources,Frameworks,SharedSupport} "$settings_app/Contents/"{MacOS,Resources}
ditto "$runtime/Frameworks/librime.1.dylib" "$app/Contents/Frameworks/librime.1.dylib"
ditto "$runtime/Frameworks/rime-plugins" "$app/Contents/Frameworks/rime-plugins"
ditto "$runtime/SharedSupport" "$app/Contents/SharedSupport"
cp data/qingtype/double_pinyin_flypy.schema.yaml "$app/Contents/SharedSupport/"
cp data/qingtype/qingtype_double_pinyin.schema.yaml "$app/Contents/SharedSupport/"
cp LICENSE.txt "$app/Contents/Resources/"
cp THIRD_PARTY.md "$app/Contents/Resources/"
python3 scripts/make-bundles.py "$app" "$settings_app"

swift build --package-path dependencies -c release
yaml_build_dir=$(swift build --package-path dependencies -c release --show-bin-path)
install -m 644 dependencies/.build/checkouts/Yams/LICENSE "$app/Contents/Resources/Yams-LICENSE.txt"
install -m 644 dependencies/.build/checkouts/Yams/LICENSE "$settings_app/Contents/Resources/Yams-LICENSE.txt"
yaml_flags=(-I "$yaml_build_dir" -I "$yaml_build_dir/Modules" -I dependencies/.build/checkouts/Yams/Sources/CYaml/include -L "$yaml_build_dir" -lQingTypeYAML)
echo "编译清言输入法…"
swiftc -parse-as-library -swift-version 5 -enable-bare-slash-regex -module-name QingType \
  -I librime/src -I librime/include -import-objc-header sources/Squirrel-Bridging-Header.h \
  sources/*.swift shared/*.swift "${yaml_flags[@]}" \
  -L "$app/Contents/Frameworks" -lrime.1 \
  -framework AppKit -framework Carbon -framework InputMethodKit -framework QuartzCore \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/QingType"

echo "编译清言设置…"
swiftc -parse-as-library -swift-version 5 -module-name QingTypeSettings \
  settings/*.swift shared/*.swift "${yaml_flags[@]}" -framework SwiftUI -framework AppKit \
  -o "$settings_app/Contents/MacOS/QingTypeSettings"

swift scripts/generate-icons.swift "$app/Contents/Resources" "$settings_app/Contents/Resources"
codesign --force --sign - "$settings_app"
find "$app/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "构建完成：$app"
