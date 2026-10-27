#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/version.py read >/dev/null
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "清言仅支持 M 芯片 Mac，请使用原生 arm64 终端构建。" >&2
  exit 1
fi

# Default runtime is extracted from a hash-pinned official archive, never installed.
# QINGTYPE_RUNTIME_APP remains an explicit developer override.
runtime_app="${QINGTYPE_RUNTIME_APP:-}"
if [[ -z "$runtime_app" ]]; then
  runtime_app=$(python3 scripts/fetch-runtime.py)
fi
runtime="$runtime_app/Contents"
if [[ ! -f "$runtime/Frameworks/librime.1.dylib" ]]; then
  echo "找不到完整的 Rime 运行库，请重新获取依赖或检查 QINGTYPE_RUNTIME_APP。" >&2
  exit 1
fi
if [[ ! -f librime/src/rime_api.h ]]; then
  git submodule update --init --depth 1 librime
fi

app="$PWD/build/QingType.app"
settings_app="$app/Contents/Applications/QingType Settings.app"
rm -rf "$app/Contents/Frameworks" "$app/Contents/SharedSupport"
mkdir -p "$app/Contents/"{MacOS,Resources,Frameworks,SharedSupport} "$settings_app/Contents/"{MacOS,Resources}
ditto "$runtime/Frameworks/librime.1.dylib" "$app/Contents/Frameworks/librime.1.dylib"
ditto "$runtime/Frameworks/rime-plugins" "$app/Contents/Frameworks/rime-plugins"
ditto "$runtime/SharedSupport" "$app/Contents/SharedSupport"
# Upstream also ships legacy optional grammar data. QingType starts without models.
find "$app/Contents/SharedSupport" -type f -name '*.gram' -delete
cp data/qingtype/double_pinyin_flypy.schema.yaml "$app/Contents/SharedSupport/"
cp data/qingtype/qingtype_double_pinyin.schema.yaml "$app/Contents/SharedSupport/"
cp LICENSE.txt "$app/Contents/Resources/"
cp THIRD_PARTY.md "$app/Contents/Resources/"
cp librime/LICENSE "$app/Contents/Resources/librime-LICENSE.txt"
cp data/qingtype/LICENSE.double-pinyin "$app/Contents/Resources/Xiaohe-LICENSE.txt"
python3 scripts/make-bundles.py "$app" "$settings_app"

swift build --package-path dependencies -c release
yaml_build_dir=$(swift build --package-path dependencies -c release --show-bin-path)
install -m 644 dependencies/.build/checkouts/Yams/LICENSE "$app/Contents/Resources/Yams-LICENSE.txt"
install -m 644 dependencies/.build/checkouts/Yams/LICENSE "$settings_app/Contents/Resources/Yams-LICENSE.txt"
yaml_flags=(-I "$yaml_build_dir" -I "$yaml_build_dir/Modules" -I dependencies/.build/checkouts/Yams/Sources/CYaml/include -L "$yaml_build_dir" -lQingTypeYAML)
compile_target="$(uname -m)-apple-macos14.0"
echo "编译清言输入法…"
swiftc -parse-as-library -swift-version 5 -enable-bare-slash-regex -module-name QingType \
  -target "$compile_target" \
  -I librime/src -I librime/include -import-objc-header sources/Squirrel-Bridging-Header.h \
  sources/*.swift shared/*.swift "${yaml_flags[@]}" \
  -L "$app/Contents/Frameworks" -lrime.1 \
  -framework AppKit -framework Carbon -framework InputMethodKit -framework QuartzCore \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$app/Contents/MacOS/QingType"

echo "编译清言设置…"
swiftc -parse-as-library -swift-version 5 -module-name QingTypeSettings \
  -target "$compile_target" \
  settings/*.swift shared/*.swift "${yaml_flags[@]}" -framework SwiftUI -framework AppKit \
  -o "$settings_app/Contents/MacOS/QingTypeSettings"

swift scripts/generate-icons.swift "$app/Contents/Resources" "$settings_app/Contents/Resources"
python3 scripts/build-provenance.py "$app" "$settings_app" "$runtime_app"
codesign --force --sign - "$settings_app"
find "$app/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "构建完成：$app"
