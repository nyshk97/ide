#!/usr/bin/env bash
# ide のフロントウィンドウだけをキャプチャして指定パスに保存。
# 使い方: scripts/ide-screenshot.sh <output_path>
set -euo pipefail

OUT="${1:-/tmp/ide-screenshot.png}"

POS=$(osascript <<'AS'
tell application "System Events" to tell process "ide"
  if (count of windows) = 0 then return "0,0,0,0"
  set p to position of front window
  set s to size of front window
  return ((item 1 of p) as string) & "," & ((item 2 of p) as string) & "," & ((item 1 of s) as string) & "," & ((item 2 of s) as string)
end tell
AS
)

if [[ "$POS" == "0,0,0,0" ]]; then
  echo "error: ide にウィンドウがない" >&2
  exit 1
fi

screencapture -x -R"$POS" "$OUT"
echo "$OUT"
