#!/usr/bin/env bash
# Ghostty 標準テーマ集を Resources/ghostty/themes/ に取得する。
#
# ide が組み込んでいる libghostty (GhosttyKit.xcframework) には標準テーマが
# 同梱されていないため、`theme = "GitHub Dark"` のような設定が解決できず
# デフォルト配色にフォールバックしてしまう。スタンドアロン Ghostty.app と
# 同じ挙動にするため、テーマファイルを bundle して GHOSTTY_RESOURCES_DIR で
# 参照させる（cmux と同じやり方）。
#
# 取得元: https://github.com/mbadolato/iTerm2-Color-Schemes (ghostty/ ディレクトリ)
#   ※ Ghostty 本体もここをベンダリングしてテーマ集を生成している
# テーマを更新したくなったら再実行する。差分は git で確認すること。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Resources/ghostty/themes"
THEMES_REPO="https://github.com/mbadolato/iTerm2-Color-Schemes.git"
REF="${1:-master}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> cloning iTerm2-Color-Schemes ($REF) ghostty themes (sparse)…"
git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$REF" "$THEMES_REPO" "$tmp/repo"
git -C "$tmp/repo" sparse-checkout set --no-cone ghostty

src="$tmp/repo/ghostty"
if [ ! -d "$src" ]; then
  echo "error: ghostty themes directory not found in repo (looked at ghostty/)" >&2
  exit 1
fi

count="$(find "$src" -type f | wc -l | tr -d ' ')"
echo "==> found $count theme files"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$src"/. "$DEST"/

# Ghostty が GHOSTTY_RESOURCES_DIR を「リソースルート」とみなすので、
# 期待されるディレクトリ構成は <root>/themes/<theme files> になる。
echo "==> wrote themes to $DEST"
echo "    bundled: $(find "$DEST" -type f | wc -l | tr -d ' ') files"
echo
echo "次に: project.yml に Resources/ghostty が含まれていることを確認し、mise run build"
