#!/bin/bash
set -euo pipefail
destination="$HOME/Library/Input Methods/QingType.app"
if [[ -x "$destination/Contents/MacOS/QingType" ]]; then
  "$destination/Contents/MacOS/QingType" --disable-input-source
  "$destination/Contents/MacOS/QingType" --quit
  # Move to Trash so the development installation can be recovered.
  mkdir -p "$HOME/.Trash"
  mv "$destination" "$HOME/.Trash/QingType-$(date +%Y%m%d-%H%M%S).app"
fi
echo "已移走清言输入法程序。配置与词库保留在 ~/Library/QingType。"
