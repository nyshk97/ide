#!/usr/bin/env bash
# PolePole を kill してから新規起動。動作確認の冒頭で使う。
# 使い方: scripts/polepole-launch.sh [wait_seconds]
set -euo pipefail

WAIT="${1:-3}"
# Debug ビルドは PRODUCT_NAME="PolePole Dev" なので app/プロセス名も "PolePole Dev"。
# Brew 配布版 (Release: "PolePole") を巻き添えで殺さないように、ここでは Dev だけを対象にする。
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP がない。先に mise run build を実行する" >&2
  exit 1
fi

pkill -x "PolePole Dev" >/dev/null 2>&1 || true
sleep 0.5
open -n "$APP"
sleep "$WAIT"

if ! pgrep -f "PolePole Dev.app/Contents/MacOS/PolePole Dev" >/dev/null 2>&1; then
  echo "error: PolePole Dev が起動していない" >&2
  exit 1
fi
