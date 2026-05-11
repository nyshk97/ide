#!/usr/bin/env bash
# ide にキーストロークを送る。Enter で確定する場合は --enter を末尾に付ける。
# 使い方:
#   scripts/ide-keystroke.sh "echo hello"          # text のみ
#   scripts/ide-keystroke.sh --enter "echo hello"  # text + Enter (key code 36)
#   scripts/ide-keystroke.sh --keycode 53          # Esc などの単独キー
set -euo pipefail

ENTER=0
KEYCODE=""
TEXT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enter)   ENTER=1; shift ;;
    --keycode) KEYCODE="$2"; shift 2 ;;
    *)         TEXT="$1"; shift ;;
  esac
done

osascript <<EOF
tell application "System Events"
  tell process "IDE Dev"
    set frontmost to true
  end tell
  delay 0.2
$( [[ -n "$TEXT" ]] && printf '  keystroke "%s"\n' "${TEXT//\"/\\\"}" )
$( [[ -n "$KEYCODE" ]] && printf '  key code %s\n' "$KEYCODE" )
$( [[ "$ENTER" == "1" ]] && printf '  delay 0.1\n  key code 36\n' )
end tell
EOF
