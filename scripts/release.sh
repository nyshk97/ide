#!/usr/bin/env bash
# build.sh で作った zip を配信 repo (nyshk97/polepole-releases) の GitHub Release に上げ、
# appcast.xml を生成する。Sparkle は `latest/download/appcast.xml` を見て更新する。
#
# 注: 本体 repo の名前は歴史的事情で `nyshk97/ide` のまま（リネームしない方針）。
#     polepole の配信は polepole-releases に集約していて、本体 repo には触らない
#     （旧 v0.0.x〜v1.0.14 の release は ide 配布の凍結履歴として残している）。
#
# 使い方: scripts/release.sh <version>
#   例: scripts/release.sh 1.0.0
#
# 注: このスクリプトは内部で build.sh を再実行する（fresh build を強制）。
#     事前に build.sh 単体を叩く必要は無く、叩くと archive→notarize→zip を 2 回
#     走らせて 10〜15 分無駄になる。release 作業は release.sh 1 発で十分。
#
# 前提:
#   - `project.yml` の MARKETING_VERSION を <version> に bump してコミット済みであること
#     （release.sh は project.yml をいじらない。タグ名と notes に <version> を使うだけ）
#   - macOS Keychain に Sparkle の EdDSA 秘密鍵が登録済みであること
#     （`generate_keys` で作成。`sign_update` が暗黙的に参照する）
#   - `gh` で nyshk97/polepole-releases に push 権限があること
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ZIP_PATH="$PROJECT_ROOT/build/polepole.zip"
APPCAST_PATH="$PROJECT_ROOT/build/appcast.xml"
RELEASES_REPO="nyshk97/polepole-releases"
FEED_URL="https://github.com/${RELEASES_REPO}/releases/latest/download/appcast.xml"
DERIVED_DATA="${POLEPOLE_RELEASE_DERIVED_DATA:-/tmp/polepole-build-release}"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.0.0"
  exit 1
fi

VERSION="$1"
TAG="v$VERSION"

echo "==> Running fresh build (always rebuild to avoid uploading stale zip)..."
"$SCRIPT_DIR/build.sh"

echo "==> Pushing main to origin (so the tag references the released commit)..."
git push origin main

# sign_update は SwiftPM が落としてきた Sparkle artifacts の中にある。
# build.sh が -derivedDataPath を固定しているので、パスが特定できる。
SIGN_UPDATE="${DERIVED_DATA}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
  echo "ERROR: sign_update not found at $SIGN_UPDATE"
  echo "       build.sh が DerivedData を別パスに書き出している可能性。POLEPOLE_RELEASE_DERIVED_DATA を確認してください。"
  exit 1
fi

echo "==> Signing zip with EdDSA..."
SIG_OUTPUT=$("$SIGN_UPDATE" "$ZIP_PATH")
echo "$SIG_OUTPUT"
ED_SIG=$(echo "$SIG_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')
LENGTH=$(echo "$SIG_OUTPUT" | sed -nE 's/.*length="([^"]+)".*/\1/p')
if [ -z "$ED_SIG" ] || [ -z "$LENGTH" ]; then
  echo "ERROR: failed to parse sign_update output"
  exit 1
fi

# sparkle:version は CFBundleVersion / sparkle:shortVersionString は
# CFBundleShortVersionString を入れる（Sparkle は前者で比較する）。
# project.yml の MARKETING_VERSION と CURRENT_PROJECT_VERSION (= $(MARKETING_VERSION))
# を bump したかをここで sanity check する。zip 内ではなく export 済み .app から読む。
BUILT_APP="/tmp/polepole-export/PolePole.app"
BUNDLE_VERSION=$(plutil -extract CFBundleVersion raw "${BUILT_APP}/Contents/Info.plist")
SHORT_VERSION=$(plutil -extract CFBundleShortVersionString raw "${BUILT_APP}/Contents/Info.plist")
if [ "$SHORT_VERSION" != "$VERSION" ]; then
  echo "ERROR: built CFBundleShortVersionString ($SHORT_VERSION) != requested <version> ($VERSION)"
  echo "       project.yml の MARKETING_VERSION を $VERSION に bump し忘れていませんか?"
  exit 1
fi
if [ "$BUNDLE_VERSION" = "1" ] && [ "$VERSION" != "1" ]; then
  echo "ERROR: CFBundleVersion=1 のまま。project.yml の CURRENT_PROJECT_VERSION が"
  echo "       MARKETING_VERSION と連動しているか確認（'\$(MARKETING_VERSION)' になっているか）"
  exit 1
fi

echo "==> Generating appcast.xml..."
# pubDate は RFC 822。LC_ALL=C で曜日 / 月名を英語に固定する（caller の LANG が ja_JP 等だと「木」「5月」になり Sparkle がパースできない）
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/${RELEASES_REPO}/releases/download/${TAG}/polepole.zip"
MIN_OS=$(awk -F'"' '/macOS:/ {print $2; exit}' "$PROJECT_ROOT/project.yml")
MIN_OS="${MIN_OS:-14.0}"

# 既存 appcast を取得（初回は空の RSS テンプレを用意）。
# appcast.xml は累積（過去バージョンも残す）= Sparkle 標準的な運用。
TMP_APPCAST="$(mktemp)"
trap 'rm -f "$TMP_APPCAST"' EXIT
if curl -fsSL "${FEED_URL}" -o "$TMP_APPCAST" 2>/dev/null && grep -q "<rss" "$TMP_APPCAST"; then
  echo "    Fetched existing appcast.xml from ${FEED_URL}"
else
  echo "    No existing appcast.xml; creating fresh"
  cat > "$TMP_APPCAST" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>PolePole</title>
    <link>${FEED_URL}</link>
    <description>Most recent PolePole updates</description>
    <language>en</language>
  </channel>
</rss>
EOF
fi

NEW_ITEM="    <item>
      <title>${SHORT_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <enclosure
        url=\"${DOWNLOAD_URL}\"
        sparkle:edSignature=\"${ED_SIG}\"
        length=\"${LENGTH}\"
        type=\"application/octet-stream\" />
    </item>"

# python3 で </channel> の直前に挿入する。シェル変数経由でクオートが二重に
# エスケープされる罠を避けるため、新 item は環境変数で渡す。
NEW_ITEM_ENV="$NEW_ITEM" python3 - "$TMP_APPCAST" "$APPCAST_PATH" <<'PY'
import os, sys
inp, out = sys.argv[1], sys.argv[2]
new_item = os.environ['NEW_ITEM_ENV']
with open(inp) as f:
    body = f.read()
needle = '  </channel>'
if needle not in body:
    raise SystemExit("ERROR: no '  </channel>' found in appcast.xml")
body = body.replace(needle, new_item + '\n' + needle, 1)
with open(out, 'w') as f:
    f.write(body)
PY

echo "    Generated $APPCAST_PATH"

# polepole の release は polepole-releases にだけ配置する。
# - 旧 ide cask 時代は nyshk97/ide 本体 repo にも release を残して homebrew cask の
#   URL を揃えていたが、polepole.rb の url は polepole-releases を直接指すので
#   本体 repo への重複 release は不要 (本体 repo の release 履歴 v0.0.x〜v1.0.14 は
#   旧 ide 配布の凍結履歴として残す)。
echo "==> Creating release on ${RELEASES_REPO} (Sparkle feed + cask zip)..."
gh release create "$TAG" \
  "$ZIP_PATH" \
  "$APPCAST_PATH" \
  --repo "${RELEASES_REPO}" \
  --title "$TAG" \
  --notes "polepole $VERSION"

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo ""
echo "==> Release created: $TAG"
echo "==> Feed URL:        ${FEED_URL}"
echo "==> Download URL:    ${DOWNLOAD_URL}"
echo "==> SHA256:          $SHA256"
echo "==> EdDSA signed:    ${ED_SIG:0:24}..."
echo ""
echo "Homebrew cask 更新時（nyshk97/homebrew-tap/Casks/polepole.rb）:"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA256\""
