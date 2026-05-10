#!/usr/bin/env bash
# build.sh で作った zip をローカルの /Applications にインストールする。
# brew cask を介さずに最新ビルドを試したいとき用。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ZIP_PATH="$PROJECT_ROOT/build/ide.zip"

if [ ! -f "$ZIP_PATH" ]; then
  echo "==> build/ide.zip not found. Running build first..."
  "$SCRIPT_DIR/build.sh"
fi

echo "==> Installing to /Applications..."
cd /tmp
rm -rf IDE.app
unzip -q -o "$ZIP_PATH"
rm -rf /Applications/IDE.app
mv IDE.app /Applications/

echo "==> Done: /Applications/IDE.app"
