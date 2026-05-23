#!/usr/bin/env bash
# Release 版 PolePole.app をアーカイブ → Developer ID 署名で書き出し → notarize → staple →
# build/polepole.zip に出力する。brew cask 配布用。
#
# 前提（一度だけ手作業で用意する）:
#   1. キーチェーンに "Developer ID Application: ... (VYDUR99LAM)" 証明書がある
#      （Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application）
#   2. notarytool の認証情報を keychain profile "ide-notary" に保存済み:
#        xcrun notarytool store-credentials "ide-notary" \
#          --apple-id <Apple ID> --team-id VYDUR99LAM --password <App用パスワード>
#      （ide → polepole にリネームしたが、keychain profile 名は流用するため "ide-notary" のまま）
# NOTARY_PROFILE 環境変数で profile 名を上書きできる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_ROOT/polepole.xcodeproj"
ARCHIVE_PATH="/tmp/polepole.xcarchive"
EXPORT_PATH="/tmp/polepole-export"
OUTPUT_DIR="$PROJECT_ROOT/build"
NOTARY_PROFILE="${NOTARY_PROFILE:-ide-notary}"
# DerivedData を固定パスにしておく。release.sh が SwiftPM 経由でチェックアウト
# された Sparkle の sign_update を `${DERIVED_DATA}/SourcePackages/artifacts/sparkle/...`
# から呼ぶため、archive 後にパスが特定できる必要がある（既定の ~/Library/Developer/Xcode/DerivedData/<hash>/ だと毎回パスが変わる）。
DERIVED_DATA="${POLEPOLE_RELEASE_DERIVED_DATA:-/tmp/polepole-build-release}"

cd "$PROJECT_ROOT"

echo "==> Regenerating Xcode project..."
mise run regen >/dev/null

echo "==> Archiving (Release)..."
rm -rf "$ARCHIVE_PATH"
xcodebuild -project "$PROJECT" \
  -scheme polepole \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  archive \
  -quiet

echo "==> Exporting (Developer ID)..."
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$PROJECT_ROOT/ExportOptions.plist" \
  -quiet

APP="$EXPORT_PATH/PolePole.app"

echo "==> Verifying signature..."
codesign --verify --strict --deep "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags'

echo "==> Notarizing (profile: $NOTARY_PROFILE)..."
NOTARIZE_ZIP="/tmp/polepole-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Packaging (ditto preserves framework symlinks; plain zip flattens them and breaks codesign)..."
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/polepole.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/polepole.zip"

echo "==> Done: $OUTPUT_DIR/polepole.zip"
shasum -a 256 "$OUTPUT_DIR/polepole.zip"
