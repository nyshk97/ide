#!/usr/bin/env bash
# build.sh で作った dmg を配信 repo (nyshk97/polepole-releases) の GitHub Release に上げ、
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
#     事前に build.sh 単体を叩く必要は無く、叩くと archive→notarize→dmg を 2 回
#     走らせて 10〜15 分無駄になる。release 作業は release.sh 1 発で十分。
#
# 前提:
#   - docs/CHANGELOG.md の [Unreleased] を埋めてコミット済みであること（空なら止まる。
#     Claude Code のセッションが git log を読んで書く。対話の pause は無い）
#   - `project.yml` の MARKETING_VERSION は release.sh が <version> に bump して CHANGELOG の
#     切り出しと同じ commit にする（bump 済みならそのまま）
#   - Claude Code のセッションから叩いてよい。push 前に失敗したらその commit は trap で巻き戻る。
#     唯一の条件は notarize の数分間に画面がロックされないこと（preflight でロック中は止める）
#   - macOS Keychain に Sparkle の EdDSA 秘密鍵が登録済みであること
#     （`generate_keys` で作成。`sign_update` が暗黙的に参照する）
#   - `gh` で nyshk97/polepole-releases に push 権限があること
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DMG_PATH="$PROJECT_ROOT/build/polepole.dmg"
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
CHANGELOG="$PROJECT_ROOT/docs/CHANGELOG.md"
RELEASE_NOTES_MD="$PROJECT_ROOT/build/release-notes-${VERSION}.md"
SPARKLE_DESC_HTML="$PROJECT_ROOT/build/sparkle-description-${VERSION}.html"
mkdir -p "$PROJECT_ROOT/build"

# === Step 0: preflight (リポジトリを書き換える前に環境を検証する) ===
# release.sh は Step 2 で CHANGELOG を commit するため、後半で死ぬ環境要因は
# ここで先に落とす。1.4.17 リリースで xcode-select が CLT を向いたまま archive まで
# 進んで失敗し、CHANGELOG commit の手動巻き戻しが必要になった実績あり。
if ! xcodebuild -version >/dev/null 2>&1; then
  if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "==> preflight: xcode-select が Xcode を向いていないため DEVELOPER_DIR=${DEVELOPER_DIR} で続行します"
    echo "    (恒久修正: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer)"
  fi
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "ERROR: xcodebuild が使えません (Xcode.app が見つからない)。"
  echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer を実行してください"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh が未認証です。gh auth login を実行してください (Release 作成は最終 step で必要)"
  exit 1
fi
# 作業ツリーが clean で origin/main と一致していること。Step 2 の commit に無関係な変更を
# 巻き込まない／別クローンからリリース済みの遅れた main で二重リリースしないため。
if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: 作業ツリーに未コミットの変更があります。CHANGELOG の [Unreleased] も含めて commit してから実行してください"
  git status --short
  exit 1
fi
git fetch -q origin --tags
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "ERROR: HEAD が origin/main と一致しません（pull 忘れ / push 忘れ）"
  echo "       local : $(git rev-parse --short HEAD) / origin: $(git rev-parse --short origin/main)"
  exit 1
fi
if gh release view "$TAG" --repo "$RELEASES_REPO" >/dev/null 2>&1; then
  echo "ERROR: ${RELEASES_REPO} に Release $TAG が既にあります"
  exit 1
fi
# 画面ロック中は notarytool の資格情報（data-protection keychain）が読めない。
# archive に数分かけてから落ちないよう先に見る
CONSOLE_LOCKED=$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleLocked raw -o - - 2>/dev/null || true)
if [ "$CONSOLE_LOCKED" = "true" ]; then
  echo "ERROR: 画面がロックされています。解除してから実行してください"
  exit 1
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-nyshk97-notary}"
if ! notary_out=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then
  echo "ERROR: notarize の keychain プロファイル '${NOTARY_PROFILE}' が使えません:"
  echo "$notary_out" | head -3
  exit 1
fi
if ! security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
  echo "ERROR: Sparkle の EdDSA 秘密鍵が keychain にありません"
  exit 1
fi

# === Step 1: CHANGELOG の確認 ===
# release.sh は CHANGELOG.md の [Unreleased] section をリリースノートとして使う。
# 埋めるのは叩く前（Claude Code のセッションが git log を読んで書き、commit する）。
# 空なら Step 2 で止まる。参考として前回リリース以降の commit を表示するだけ。
if [ ! -f "$CHANGELOG" ]; then
  echo "ERROR: $CHANGELOG が見つかりません"
  exit 1
fi
if ! grep -q "^## \[Unreleased\]" "$CHANGELOG"; then
  echo "ERROR: docs/CHANGELOG.md に '## [Unreleased]' セクションがありません"
  exit 1
fi

# 直前リリースの version を CHANGELOG.md から拾う ([Unreleased] の次の ## [X.Y.Z])
LAST_VERSION=$(awk '/^## \[Unreleased\]/{f=1; next} f && /^## \[([^]]+)\]/{match($0, /\[([^]]+)\]/); print substr($0, RSTART+1, RLENGTH-2); exit}' "$CHANGELOG")
if [ -n "$LAST_VERSION" ] && git rev-parse "v${LAST_VERSION}" >/dev/null 2>&1; then
  echo ""
  echo "==> 前回リリース v${LAST_VERSION} 以降の commit:"
  # --max-count で git log 側で打ち切る (| head -100 だと head 終了の SIGPIPE で
  # git log が落ち、set -o pipefail のもと release.sh 全体が exit する)
  git log "v${LAST_VERSION}..HEAD" --max-count=100 --pretty=format:"  %h %s"
  echo ""
else
  echo ""
  echo "==> 直近 30 commit (CHANGELOG から前回リリースタグを特定できず):"
  git log -30 --pretty=format:"  %h %s"
  echo ""
fi
echo ""

# === Step 2: [Unreleased] → [<version>] - <today> 書き換え + commit ===
TODAY=$(date +%Y-%m-%d)
python3 - "$CHANGELOG" "$VERSION" "$TODAY" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
version, date = sys.argv[2], sys.argv[3]
text = path.read_text()

# 再実行ガード: 途中失敗後の再実行では [Unreleased] が空で [version] が既に存在する。
# その場合はリネーム済みとみなしてスキップする (無条件に挿入すると同名ヘッダーが
# 重複し、Step 3 が最初の空セクションを抽出して Sparkle description が空になる)。
unreleased = re.search(r"^## \[Unreleased\]\s*$(.*?)(?=^## \[|\Z)", text, flags=re.M | re.S)
if not unreleased:
    sys.exit("ERROR: [Unreleased] セクションが見つかりません")
has_content = bool(unreleased.group(1).strip())
already_renamed = re.search(rf"^## \[{re.escape(version)}\]", text, flags=re.M)

if already_renamed and not has_content:
    print(f"  CHANGELOG.md: [{version}] は既に存在し [Unreleased] は空 — リネーム済みとみなしてスキップ (再実行)")
    sys.exit(0)
if already_renamed and has_content:
    sys.exit(f"ERROR: [{version}] が既に存在するのに [Unreleased] にも内容があります。CHANGELOG を手で整理してください")
if not has_content:
    sys.exit("ERROR: [Unreleased] が空です。リリースノートを書いてから再実行してください")

new = re.sub(
    r"^## \[Unreleased\]\s*$",
    f"## [Unreleased]\n\n## [{version}] - {date}",
    text, count=1, flags=re.M,
)
path.write_text(new)
print(f"  CHANGELOG.md: [Unreleased] の下に [{version}] - {date} を挿入")
PY

# project.yml の MARKETING_VERSION も <version> に揃える（CURRENT_PROJECT_VERSION は連動）
CURRENT_MV=$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$PROJECT_ROOT/project.yml")
if [ "$CURRENT_MV" != "$VERSION" ]; then
  sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_ROOT/project.yml"
  echo "  project.yml: MARKETING_VERSION ${CURRENT_MV} → ${VERSION}"
fi

RELEASE_COMMITTED=0
if ! git diff --quiet -- "$CHANGELOG" "$PROJECT_ROOT/project.yml"; then
  git add "$CHANGELOG" "$PROJECT_ROOT/project.yml"
  git commit -q -m "chore: release ${VERSION}"
  RELEASE_COMMITTED=1
  echo "  CHANGELOG.md と project.yml を commit (release ${VERSION})"
fi
# push までに失敗したらこの commit を巻き戻す（preflight で clean worktree を保証しているので
# 消えるのはこの commit だけ）。以前は手動で巻き戻していた。
rollback_release_commit() {
  if [ "$RELEASE_COMMITTED" -eq 1 ]; then
    echo "↩️  失敗したので release commit を巻き戻します（remote は未変更）"
    git reset -q --hard HEAD~1
  fi
}
trap 'rollback_release_commit' ERR

# === Step 3: 該当 section から release notes (md) と Sparkle description (HTML) を生成 ===
python3 - "$CHANGELOG" "$VERSION" "$RELEASE_NOTES_MD" "$SPARKLE_DESC_HTML" <<'PY'
import sys, re, pathlib
md_path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
notes_path = pathlib.Path(sys.argv[3])
desc_path = pathlib.Path(sys.argv[4])
md = md_path.read_text()
pattern = re.compile(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", re.S | re.M)
m = pattern.search(md)
if not m:
    sys.exit(f"ERROR: CHANGELOG から [{version}] section を抽出できません")
body = m.group(1).strip()

# --- release notes (markdown, ja/en 両方そのまま) ---
notes = f"# PolePole {version}\n\n{body}\n"
notes_path.write_text(notes)
print(f"  Wrote {notes_path}")

# --- Sparkle description (HTML, ja のみ抽出) ---
def inline(text):
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text

# Sparkle の Update Notes は WKWebView (light/dark 自動切替なし) で描画される。
# `color-scheme: light dark` を宣言すると WebView が現在の OS テーマに従って
# default の text/background 色を切り替えてくれる。固定色 (#1d1d1f 等) を当てると
# ダーク背景に黒文字で本文が読めなくなる事故が起きるので、配色はシステムに任せる。
# code 背景も rgba グレーにして light/dark 両対応。
html = ['<style>:root{color-scheme:light dark}body{font:-apple-system-body;line-height:1.5}h3{font-size:14px;margin:16px 0 6px}ul{margin:0;padding-left:20px}li{margin:3px 0}code{background:rgba(127,127,127,0.18);padding:1px 5px;border-radius:3px;font-size:90%}</style>']
in_ul = False
for line in body.split("\n"):
    line = line.rstrip()
    if line.startswith("### "):
        if in_ul:
            html.append("</ul>"); in_ul = False
        html.append(f"<h3>{inline(line[4:])}</h3>")
    elif line.startswith("- ja:"):
        if not in_ul:
            html.append("<ul>"); in_ul = True
        html.append(f"<li>{inline(line[5:].strip())}</li>")
    elif line.startswith("- en:"):
        continue  # Sparkle JP のみ (将来 EN appcast を別途出すなら追加)
if in_ul:
    html.append("</ul>")
desc_path.write_text("\n".join(html))
print(f"  Wrote {desc_path}")
PY

echo "==> Running fresh build (always rebuild to avoid uploading stale dmg)..."
"$SCRIPT_DIR/build.sh"

echo "==> Pushing main to origin (so the tag references the released commit)..."
git push origin main
RELEASE_COMMITTED=0
trap - ERR

# sign_update は SwiftPM が落としてきた Sparkle artifacts の中にある。
# build.sh が -derivedDataPath を固定しているので、パスが特定できる。
SIGN_UPDATE="${DERIVED_DATA}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
  echo "ERROR: sign_update not found at $SIGN_UPDATE"
  echo "       build.sh が DerivedData を別パスに書き出している可能性。POLEPOLE_RELEASE_DERIVED_DATA を確認してください。"
  exit 1
fi

echo "==> Signing dmg with EdDSA..."
SIG_OUTPUT=$("$SIGN_UPDATE" "$DMG_PATH")
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
# を bump したかをここで sanity check する。dmg 内ではなく export 済み .app から読む。
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
DOWNLOAD_URL="https://github.com/${RELEASES_REPO}/releases/download/${TAG}/polepole.dmg"
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

DESC_BODY=$(cat "$SPARKLE_DESC_HTML")
NEW_ITEM="    <item>
      <title>${SHORT_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <description><![CDATA[
${DESC_BODY}
]]></description>
      <enclosure
        url=\"${DOWNLOAD_URL}\"
        sparkle:edSignature=\"${ED_SIG}\"
        length=\"${LENGTH}\"
        type=\"application/x-apple-diskimage\" />
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
echo "==> Creating release on ${RELEASES_REPO} (Sparkle feed + dmg)..."
gh release create "$TAG" \
  "$DMG_PATH" \
  "$APPCAST_PATH" \
  --repo "${RELEASES_REPO}" \
  --title "$TAG" \
  --notes-file "$RELEASE_NOTES_MD"

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo ""
echo "==> Release created: $TAG"
echo "==> Feed URL:        ${FEED_URL}"
echo "==> Download URL:    ${DOWNLOAD_URL}"
echo "==> SHA256:          $SHA256"
echo "==> EdDSA signed:    ${ED_SIG:0:24}..."
echo ""
# === Cask 更新（nyshk97/homebrew-tap/Casks/polepole.rb）===
TAP_REPO="nyshk97/homebrew-tap"
CASK_PATH="Casks/polepole.rb"
echo "==> Updating Homebrew cask ${TAP_REPO}/${CASK_PATH}..."
CASK_CONTENT="$(cat <<CASK
cask "polepole" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/${RELEASES_REPO}/releases/download/v#{version}/polepole.dmg"
  name "PolePole"
  desc "Self-hosted IDE that integrates Ghostty terminal and Claude Code"
  homepage "https://github.com/nyshk97/ide"

  auto_updates true
  depends_on macos: :sonoma

  app "PolePole.app"
end
CASK
)"
ENCODED=$(printf '%s' "$CASK_CONTENT" | base64)
EXISTING_SHA=$(gh api "repos/$TAP_REPO/contents/$CASK_PATH" --jq '.sha' 2>/dev/null || true)
if [ -n "$EXISTING_SHA" ]; then
  gh api "repos/$TAP_REPO/contents/$CASK_PATH" --method PUT \
    --field message="chore: polepole $VERSION" --field content="$ENCODED" --field sha="$EXISTING_SHA" --silent
else
  gh api "repos/$TAP_REPO/contents/$CASK_PATH" --method PUT \
    --field message="feat: add polepole $VERSION" --field content="$ENCODED" --silent
fi
# brew のローカル tap クローンは自動更新されないので pull しておく
TAP_DIR=$(brew --repository "$TAP_REPO" 2>/dev/null || true)
if [ -n "$TAP_DIR" ] && [ -d "$TAP_DIR/.git" ]; then
  git -C "$TAP_DIR" pull --ff-only --quiet origin main || true
fi
echo "==> Cask updated:    ${TAP_REPO}/${CASK_PATH} → ${VERSION}"
