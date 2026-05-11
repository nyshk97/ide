#!/usr/bin/env bash
# Release 版 IDE.app をアーカイブ → Developer ID 署名で書き出し → notarize → staple →
# build/ide.zip に出力する。brew cask 配布用。
#
# 前提（一度だけ手作業で用意する）:
#   1. キーチェーンに "Developer ID Application: ... (U4WAHGGBR7)" 証明書がある
#      （Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application）
#   2. notarytool の認証情報を keychain profile "ide-notary" に保存済み:
#        xcrun notarytool store-credentials "ide-notary" \
#          --apple-id <Apple ID> --team-id U4WAHGGBR7 --password <App用パスワード>
# NOTARY_PROFILE 環境変数で profile 名を上書きできる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_ROOT/ide.xcodeproj"
ARCHIVE_PATH="/tmp/ide.xcarchive"
EXPORT_PATH="/tmp/ide-export"
OUTPUT_DIR="$PROJECT_ROOT/build"
NOTARY_PROFILE="${NOTARY_PROFILE:-ide-notary}"

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

echo "==> Exporting (Developer ID)..."
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$PROJECT_ROOT/ExportOptions.plist" \
  -quiet

APP="$EXPORT_PATH/IDE.app"

echo "==> Verifying signature..."
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags'

echo "==> Notarizing (profile: $NOTARY_PROFILE)..."
NOTARIZE_ZIP="/tmp/ide-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Packaging..."
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/ide.zip"
cd "$EXPORT_PATH"
zip -r -q "$OUTPUT_DIR/ide.zip" IDE.app

echo "==> Done: $OUTPUT_DIR/ide.zip"
shasum -a 256 "$OUTPUT_DIR/ide.zip"
