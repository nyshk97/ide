#!/usr/bin/env bash
# Release 版 PolePole.app をアーカイブ → Developer ID 署名で書き出し → notarize → staple →
# build/polepole.dmg に出力する。LP の直リンクと brew cask 配布の両方で使う。
#
# DMG 化のフロー: notarized + stapled .app を create-dmg で dmg に詰め、dmg 自体も
# --codesign / --notarize で codesign + notarize + staple する。.app と dmg の両方に
# ticket が乗るため、ユーザーは初回起動でもオフラインで Gatekeeper を通せる。
#
# 前提（一度だけ手作業で用意する）:
#   1. キーチェーンに "Developer ID Application: ... (VYDUR99LAM)" 証明書がある
#      （Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application）
#   2. notarytool の認証情報を keychain profile "nyshk97-notary" に保存済み。
#      App Store Connect の API キー（.p8 は Dropbox の secrets/）で登録する:
#        xcrun notarytool store-credentials nyshk97-notary \
#          --key ~/Library/CloudStorage/Dropbox/secrets/AuthKey_M4FG2B8JFX.p8 \
#          --key-id M4FG2B8JFX --issuer 024fc873-10f9-49a4-8d6f-20fb5c7bd522
#      （自作 Mac アプリ全体で共通のプロファイル名。App 用パスワードは使わない）
#   3. create-dmg (Brewfile 経由でインストール済み)
# NOTARY_PROFILE 環境変数で profile 名を上書きできる。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_ROOT/polepole.xcodeproj"
ARCHIVE_PATH="/tmp/polepole.xcarchive"
EXPORT_PATH="/tmp/polepole-export"
OUTPUT_DIR="$PROJECT_ROOT/build"
NOTARY_PROFILE="${NOTARY_PROFILE:-nyshk97-notary}"
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

echo "==> Notarizing app (profile: $NOTARY_PROFILE)..."
NOTARIZE_ZIP="/tmp/polepole-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling app..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Packaging into DMG..."
mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/polepole.dmg"
rm -f "$DMG_PATH"
DMG_SRC_DIR="/tmp/polepole-dmg-src"
rm -rf "$DMG_SRC_DIR"
mkdir -p "$DMG_SRC_DIR"
# ditto は framework 内 symlink を保持する。cp -R や zip は flatten して codesign を壊す
ditto "$APP" "$DMG_SRC_DIR/PolePole.app"

# Developer ID Application 証明書を Team ID で絞り込む（keychain に複数あっても誤爆しない）
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application.*VYDUR99LAM/ {print $2; exit}')
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "ERROR: Developer ID Application (Team VYDUR99LAM) 証明書がキーチェーンに見つかりません"
  exit 1
fi

# --codesign + --notarize で dmg の codesign → notarytool submit --wait → staple を自動実行
create-dmg \
  --volname "PolePole" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "PolePole.app" 150 200 \
  --app-drop-link 450 200 \
  --hide-extension "PolePole.app" \
  --codesign "$SIGNING_IDENTITY" \
  --notarize "$NOTARY_PROFILE" \
  "$DMG_PATH" \
  "$DMG_SRC_DIR/"

echo "==> Done: $DMG_PATH"
shasum -a 256 "$DMG_PATH"
