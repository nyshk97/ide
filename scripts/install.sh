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

echo "==> Installing to /Applications (ditto preserves framework symlinks; plain unzip flattens them and breaks codesign)..."
STAGE=$(mktemp -d)
ditto -x -k "$ZIP_PATH" "$STAGE"
rm -rf /Applications/IDE.app
mv "$STAGE/IDE.app" /Applications/
rm -rf "$STAGE"

echo "==> Done: /Applications/IDE.app"
