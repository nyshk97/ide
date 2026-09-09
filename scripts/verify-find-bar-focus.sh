#!/usr/bin/env bash
# 検索バー表示中にターミナルへフォーカスを移したとき、Return / Esc が端末に届くかの e2e 検査。
# Debug 限定の POLEPOLE_TEST_EVENT_FILE 注入フックでキーを流す（osascript 不要）。VERIFY.md §26-b。
# 事前に mise run build が必要。
set -uo pipefail
cd "$(dirname "$0")/.."
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
LOG=/tmp/polepole-poc.log
EV=$(mktemp /tmp/polepole-ev.XXXXXX)
MARK=$(mktemp -u /tmp/polepole-find-enter.XXXXXX)
BACKUP_DIR=$(mktemp -d)
FAILS=0
ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }

cp -a "$HOME/Library/Application Support/polepole-dev" "$BACKUP_DIR/polepole-dev" 2>/dev/null || true
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
find "$HOME/Library/Application Support/polepole-dev" -maxdepth 1 -name 'projects.json.[0-9]' -delete

# split の autosave にプレビュー列 collapsed=YES が残っていると、起動時の復元で KVO 経由の
# preview.close() が走り AUTO_PREVIEW が閉じられる（テスト経路だけの起動レース）→ 消してから起動
defaults delete local.d0ne1s.polepole.dev "NSSplitView Subview Frames polepole.rootSplit.v2" 2>/dev/null || true
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.6
: > "$EV"
open -n "$APP" --env POLEPOLE_TEST_EVENT_FILE="$EV" \
  --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 \
  --env POLEPOLE_TEST_AUTO_PREVIEW="Sources/polepole/ProjectsModel.swift" \
  --env POLEPOLE_TEST_PREVIEW_FIND="preview"

for _ in $(seq 1 30); do
  sleep 0.5
  grep -q "\[test-event\] watching" "$LOG" 2>/dev/null && grep -q "test-preview-find" "$LOG" && break
done
grep -q "\[test-event\] watching" "$LOG" && ok "injector armed" || fail "injector not armed"
grep -q "\[license\] state = activated" "$LOG" && ok "license activated" || fail "license not activated: $(grep '\[license\]' "$LOG" | tail -1)"
grep -q "\[find\] hide" "$LOG" && fail "find bar was closed before injection (preview pane collapsed at startup?)" || ok "find bar open at startup"
sleep 3   # シェルのプロンプトが出るまで

send() { echo "$1" >> "$EV"; sleep 0.6; }

# 1) 検索バーを開いたままターミナルへフォーカス → touch + Return が実行される
send '{"type":"focus","target":"terminal"}'
grep -q "focus terminal -> firstResponder=GhosttyTerminalNSView" "$LOG" && ok "terminal is first responder" || fail "terminal focus: $(grep 'focus terminal' "$LOG" | tail -1)"
send "{\"type\":\"text\",\"text\":\"touch $MARK\"}"
send '{"type":"key","keyCode":36}'
sleep 2
[ -e "$MARK" ] && ok "Return reached terminal (marker created)" || fail "Return swallowed (marker missing)"
grep -q "\[find\] next" "$LOG" && fail "Return triggered findNext" || ok "findNext not triggered"

# 2) Esc も端末へ（検索バーは閉じない）
send '{"type":"key","keyCode":53}'
grep -q "\[find\] hide" "$LOG" && fail "Esc closed the find bar" || ok "find bar stays open on Esc"

# 3) 入力欄に戻せば Return は従来どおり次のマッチ
send '{"type":"focus","target":"find"}'
sleep 0.5
grep -qE "focus find settled -> firstResponder=(NSTextView|_SystemTextFieldFieldEditor)" "$LOG" && ok "find field is first responder" || fail "find field focus: $(grep 'focus find' "$LOG" | tail -1)"
send '{"type":"key","keyCode":36}'
grep -q "\[find\] next forward=true" "$LOG" && ok "Return in find field -> findNext" || fail "findNext not fired in find field"

pkill -x "PolePole Dev" 2>/dev/null
rm -f "$EV" "$MARK"
rm -rf "$HOME/Library/Application Support/polepole-dev"
mv "$BACKUP_DIR/polepole-dev" "$HOME/Library/Application Support/polepole-dev" 2>/dev/null || true
echo "--- failures: $FAILS"
exit $FAILS
