#!/usr/bin/env bash
# Cmd+O プロジェクト検索の e2e 検査。起動・絞り込み（名前 / パス）・選択移動・確定・キャンセル・トグルを
# Debug 限定の POLEPOLE_TEST_EVENT_FILE 注入フックで流して、[project-search] ログで判定する。VERIFY.md §42。
# 事前に mise run build が必要。
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
LOG=/tmp/polepole-poc.log
EV=$(mktemp /tmp/polepole-ev.XXXXXX)
BACKUP_DIR=$(mktemp -d)
FAILS=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }

cp -a "$HOME/Library/Application Support/polepole-dev" "$BACKUP_DIR/polepole-dev" 2>/dev/null || true
mkdir -p "$HOME/Library/Application Support/polepole-dev"
# lastOpenedAt 降順 = ide, alpha-web, beta-api, gamma-docs, missing-proj（最後はパスが存在しない）
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<JSON
{"projects":[
{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T05:00:00Z","path":"$ROOT"},
{"displayName":"alpha-web","id":"22222222-2222-2222-2222-222222222222","isPinned":false,"lastOpenedAt":"2026-05-09T04:00:00Z","path":"$ROOT/Sources"},
{"displayName":"beta-api","id":"33333333-3333-3333-3333-333333333333","isPinned":false,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"$ROOT/docs"},
{"displayName":"gamma-docs","id":"44444444-4444-4444-4444-444444444444","isPinned":false,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"$ROOT/backend"},
{"displayName":"missing-proj","id":"55555555-5555-5555-5555-555555555555","isPinned":false,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/nonexistent-polepole-xyz"}
],"schemaVersion":1}
JSON
find "$HOME/Library/Application Support/polepole-dev" -maxdepth 1 -name 'projects.json.[0-9]' -delete

pkill -x "PolePole Dev" 2>/dev/null; sleep 0.6
: > "$EV"
open -n "$APP" --env POLEPOLE_TEST_EVENT_FILE="$EV" --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0

for _ in $(seq 1 30); do
  sleep 0.5
  grep -q "\[test-event\] watching" "$LOG" 2>/dev/null && break
done
grep -q "\[test-event\] watching" "$LOG" && ok "injector armed" || fail "injector not armed"
grep -q "\[license\] state = activated" "$LOG" && ok "license activated" || fail "license not activated: $(grep '\[license\]' "$LOG" | tail -1)"
sleep 3   # シェルのプロンプトが出るまで

send() { echo "$1" >> "$EV"; sleep 0.6; }
cmd_o() { send '{"type":"key","keyCode":31,"mods":["cmd"]}'; sleep 0.4; }   # TextField のフォーカス確定待ち
enter() { send '{"type":"key","keyCode":36}'; }
# 直近の [project-search] 行（検査ごとに増えた分だけ見る）
count() { grep -c "\[project-search\] $1" "$LOG"; }
last()  { grep "\[project-search\] $1" "$LOG" | tail -1; }

# 1) ターミナルにフォーカスがあっても Cmd+O で開き、カーソルは直前のプロジェクト（index 1）
send '{"type":"focus","target":"terminal"}'
cmd_o
last "open" | grep -q "selection=1" && ok "Cmd+O opens with selection=1 from terminal" || fail "open: $(last open)"

# 2) そのまま Enter → 直前のプロジェクト alpha-web に切り替わる
enter
last "select" | grep -q "name=alpha-web active=alpha-web" && ok "Cmd+O -> Enter switches to previous project" || fail "select: $(last select)"
last "confirm" | grep -q 'results=\["ide", "alpha-web", "beta-api", "gamma-docs", "missing-proj"\]' \
  && ok "empty query lists all projects in MRU order (incl. missing)" || fail "confirm: $(last confirm)"

# 3) 名前で絞り込み: "gam" → gamma-docs
cmd_o
send '{"type":"text","text":"gam"}'
enter
last "confirm" | grep -q 'query=gam results=\["gamma-docs"\] selection=0' && ok "name fuzzy filter" || fail "confirm: $(last confirm)"
last "select" | grep -q "active=gamma-docs" && ok "switched to gamma-docs" || fail "select: $(last select)"

# 4) パスで絞り込み: "sources" → alpha-web（名前には含まれない。パス末尾が Sources）
cmd_o
send '{"type":"text","text":"sources"}'
enter
last "confirm" | grep -q 'query=sources results=\["alpha-web"' && ok "path fuzzy filter" || fail "confirm: $(last confirm)"

# 5) ヒット無し → Enter は何もしない、Esc で閉じて active は不変
before=$(count "select"); closes=$(count "close")
cmd_o
send '{"type":"text","text":"zzqx"}'
enter
send '{"type":"key","keyCode":53}'
[ "$(count "select")" = "$before" ] && ok "Enter with no results does nothing" || fail "unexpected select: $(last select)"
[ "$(count "close")" = "$((closes+1))" ] && ok "Esc closes" || fail "Esc did not close"

# 6) Ctrl+N / ↓ で選択移動。MRU = alpha-web, gamma-docs, ide, beta-api, missing-proj。初期 1 → Ctrl+N で 2 → ↓ で 3
cmd_o
send '{"type":"key","keyCode":45,"mods":["ctrl"]}'
send '{"type":"key","keyCode":125}'
enter
last "select" | grep -q "name=beta-api active=beta-api" && ok "Ctrl+N / Down move selection" || fail "select: $(last select)"

# 7) Ctrl+P で上へ（wrap）: 初期 1 → Ctrl+P で 0 → Ctrl+P で末尾 missing-proj → 開けず active 不変
cmd_o
send '{"type":"key","keyCode":35,"mods":["ctrl"]}'
send '{"type":"key","keyCode":35,"mods":["ctrl"]}'
enter
last "select" | grep -q "name=missing-proj active=beta-api" && ok "Ctrl+P wraps; missing project is selectable but not opened" || fail "select: $(last select)"

# 8) Cmd+O をもう一度押すと閉じる（トグル）
opens=$(count "open"); closes=$(count "close")
cmd_o
cmd_o
[ "$(count "open")" = "$((opens+1))" ] && [ "$(count "close")" = "$((closes+1))" ] && ok "Cmd+O toggles" || fail "toggle: open=$(count open) close=$(count close)"

pkill -x "PolePole Dev" 2>/dev/null
rm -f "$EV"
rm -rf "$HOME/Library/Application Support/polepole-dev"
mv "$BACKUP_DIR/polepole-dev" "$HOME/Library/Application Support/polepole-dev" 2>/dev/null || true
echo "--- failures: $FAILS"
exit $FAILS
