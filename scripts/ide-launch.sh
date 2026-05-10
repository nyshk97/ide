#!/usr/bin/env bash
# ide を kill してから新規起動。動作確認の冒頭で使う。
# 使い方: scripts/ide-launch.sh [wait_seconds]
set -euo pipefail

WAIT="${1:-3}"
APP=/tmp/ide-build/Build/Products/Debug/IDE.app

if [[ ! -d "$APP" ]]; then
  echo "error: $APP がない。先に mise run build を実行する" >&2
  exit 1
fi

pkill -x IDE >/dev/null 2>&1 || true
sleep 0.5
open -n "$APP"
sleep "$WAIT"

if ! pgrep -f "IDE.app/Contents/MacOS/IDE" >/dev/null 2>&1; then
  echo "error: IDE が起動していない" >&2
  exit 1
fi
