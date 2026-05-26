#!/usr/bin/env bash
# PolePole の DL 統計を 2 経路で出す:
#   1. GitHub Releases の累積 download_count (バージョン別、UA 区別なし)
#   2. Cloudflare D1 の download_event テーブル (UA 分類あり)
#
# 経路 1 は Worker 経由を実装する前から動いている既存配信を含めて見える。
# 経路 2 は Worker 経由のリクエストだけが集計されるので、新規インストール vs 自動更新を分けられる。
# 経路 2 は wrangler が無い / D1 にアクセスできない環境ではスキップする。

set -euo pipefail

REPO="nyshk97/polepole-releases"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI が必要" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq が必要" >&2
  exit 1
fi

echo "==========================================="
echo "GitHub Releases (累積 download_count)"
echo "==========================================="
echo ""

gh api "repos/${REPO}/releases?per_page=100" \
  --jq '[.[] | {
    tag: .tag_name,
    date: (.published_at | split("T")[0]),
    binary: ([.assets[] | select(.name | test("polepole\\.(zip|dmg)$")) | .download_count] | add // 0),
    appcast: ([.assets[] | select(.name == "appcast.xml") | .download_count] | add // 0)
  }]' \
  | jq -r '
    (["Version", "Released", "Binary", "Appcast"] | @tsv),
    (["-------", "----------", "------", "-------"] | @tsv),
    (.[] | [.tag, .date, (.binary | tostring), (.appcast | tostring)] | @tsv),
    (["-------", "----------", "------", "-------"] | @tsv),
    (["Total", "-", (map(.binary) | add | tostring), (map(.appcast) | add | tostring)] | @tsv)
  ' \
  | column -t -s "$(printf '\t')"

echo ""
echo "Binary  = zip/dmg ダウンロード数（新規インストール + Sparkle 自動更新が混ざる）"
echo "Appcast = appcast.xml アクセス数（直接 GitHub を叩いた古い install を含む）"
echo ""

# --- 経路 2: Cloudflare D1 ---
# wrangler は backend/ で実行する必要がある。
BACKEND_DIR="$(cd "$(dirname "$0")/.." && pwd)/backend"
if [[ ! -d "${BACKEND_DIR}" ]]; then
  exit 0
fi

# wrangler 自体は backend/ の devDependency 経由で動かす。
if ! (cd "${BACKEND_DIR}" && pnpm exec wrangler --version) >/dev/null 2>&1; then
  echo "(skipped) wrangler not available in backend/ — D1 集計はスキップ" >&2
  exit 0
fi

echo "==========================================="
echo "Cloudflare D1 (Worker 経由のリクエスト、UA 分類)"
echo "==========================================="
echo ""

# --local が来たら local SQLite を見る (開発用)。デフォルトは production の remote D1。
# 注意: 本番 D1 は `polepole-licenses-prod`、ローカルは `polepole-licenses` で名前が違う。
D1_FLAGS="--remote --env production"
D1_NAME="polepole-licenses-prod"
if [[ "${1:-}" == "--local" ]]; then
  D1_FLAGS="--local"
  D1_NAME="polepole-licenses"
  echo "(--local モード: backend/.wrangler/state の local DB を参照)"
  echo ""
fi

run_d1() {
  local sql="$1"
  (cd "${BACKEND_DIR}" && pnpm exec wrangler d1 execute "${D1_NAME}" \
    ${D1_FLAGS} --json --command "${sql}" 2>/dev/null)
}

render_breakdown() {
  local json="$1"
  # wrangler は成功時 [{"results":[...]}], 失敗時 {"error":{...}} を返す。型で分岐。
  local err
  err=$(echo "${json}" | jq -r 'if type == "object" then .error.text // "unknown error" else empty end')
  if [[ -n "${err}" ]]; then
    echo "  (D1 query 失敗: ${err})"
    echo "  → 本番 D1 / download_event テーブル未作成かもしれない。次を確認:"
    echo "      cd backend && pnpm exec wrangler d1 migrations list polepole-licenses-prod --remote --env production"
    echo "  → ローカル DB を見るには:  ./scripts/download-stats.sh --local"
    return
  fi
  local rows
  rows=$(echo "${json}" | jq -r '.[0].results | length')
  if [[ "${rows}" == "0" ]]; then
    echo "  (該当データなし)"
    return
  fi
  echo "${json}" | jq -r '
    .[0].results
    | (["Classification", "Resource", "Count"] | @tsv),
      (["--------------", "--------", "-----"] | @tsv),
      (.[] | [.classification, .resource, (.n | tostring)] | @tsv)
  ' | column -t -s "$(printf '\t')"
}

echo "--- 全期間 ---"
render_breakdown "$(run_d1 "SELECT classification, resource, COUNT(*) AS n FROM download_event GROUP BY classification, resource ORDER BY classification, resource")"

echo ""
echo "--- 直近 30 日 ---"
render_breakdown "$(run_d1 "SELECT classification, resource, COUNT(*) AS n FROM download_event WHERE occurred_at >= (strftime('%s','now') - 30*86400) * 1000 GROUP BY classification, resource ORDER BY classification, resource")"

echo ""
echo "解釈:"
echo "  download × sparkle  = Sparkle 自動更新 (既存 install の更新)"
echo "  download × homebrew = brew install (新規インストール)"
echo "  download × browser  = LP からの直接 DL (新規インストール)"
echo "  appcast  × sparkle  = 更新チェック (≒ アクティブ install 数の指標)"
