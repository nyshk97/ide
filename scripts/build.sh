#!/usr/bin/env bash
# Release 版 ide.app をアーカイブして build/ide.zip に出力する。
# brew cask 配布用。ad-hoc 署名（Apple Developer Program なし）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_ROOT/ide.xcodeproj"
ARCHIVE_PATH="/tmp/ide.xcarchive"
EXPORT_PATH="/tmp/ide-export"
OUTPUT_DIR="$PROJECT_ROOT/build"

cd "$PROJECT_ROOT"

echo "==> Regenerating Xcode project..."
mise run regen >/dev/null

echo "==> Archiving (Release)..."
rm -rf "$ARCHIVE_PATH"
xcodebuild -project "$PROJECT" \
  -scheme ide \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  -quiet

echo "==> Exporting..."
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$PROJECT_ROOT/ExportOptions.plist" \
  -quiet

echo "==> Packaging..."
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/ide.zip"
cd "$EXPORT_PATH"
zip -r -q "$OUTPUT_DIR/ide.zip" ide.app

echo "==> Done: $OUTPUT_DIR/ide.zip"
shasum -a 256 "$OUTPUT_DIR/ide.zip"
