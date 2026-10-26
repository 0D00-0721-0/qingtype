#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/build/QingType.app"
destination="$HOME/Library/Input Methods/QingType.app"
[[ -x "$source_app/Contents/MacOS/QingType" ]] || { echo "请先运行 scripts/build-dev.sh" >&2; exit 1; }
codesign --verify --deep --strict "$source_app"
mkdir -p "$HOME/Library/Input Methods" "$PWD/build/install-backups"
backup_dir=$(mktemp -d "$PWD/build/install-backups/$(date +%Y%m%d-%H%M%S)-XXXXXX")
if [[ -d "$destination" ]]; then
  "$source_app/Contents/MacOS/QingType" --quit
  ditto -c -k --keepParent "$destination" "$backup_dir/QingType.zip"
fi
ditto "$source_app" "$destination"
# Sandbox clients may otherwise reload a pre-install input-source table from
# their own IntlDataCache, then crash inside the system source-switching HUD.
python3 scripts/refresh_input_source_cache.py --backup-dir "$backup_dir/input-source-cache"
"$destination/Contents/MacOS/QingType" --register-input-source
"$destination/Contents/MacOS/QingType" --enable-input-source
# TIS caches state within a process. Verify from a fresh process after rescan.
sleep 2
"$destination/Contents/MacOS/QingType" --enable-input-source
"$destination/Contents/MacOS/QingType" --status
echo "已安装清言。请在系统输入菜单中选择清言；如未出现，请注销后重新登录。"
