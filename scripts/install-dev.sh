#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x build/QingType.app/Contents/MacOS/QingType ]] || { echo "请先运行 scripts/build-dev.sh" >&2; exit 1; }
yaml_build_dir=$(swift build --package-path dependencies -c release --show-bin-path)
swiftc -parse-as-library -swift-version 5 shared/*.swift scripts/InstallDev.swift \
  -I "$yaml_build_dir" -I "$yaml_build_dir/Modules" -I dependencies/.build/checkouts/Yams/Sources/CYaml/include \
  -L "$yaml_build_dir" -lQingTypeYAML -o build/qingtype-install-dev
exec build/qingtype-install-dev
