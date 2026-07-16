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
# ライセンス再検証を本番 API に向ける。Debug のデフォルトは 127.0.0.1:8787 (ローカル wrangler dev) で、
# ローカル backend が居ないと再検証が失敗し続け、オフライン猶予 (30日) 切れで
# トライアル/購入モーダルが復活する。ライセンスフローをローカル backend で検証するときは
# POLEPOLE_BACKEND_URL=http://127.0.0.1:8787 を付けて呼び出せば上書きできる。
open -n "$APP" --env POLEPOLE_BACKEND_URL="${POLEPOLE_BACKEND_URL:-https://polepole.dev}"
sleep "$WAIT"

if ! pgrep -f "PolePole Dev.app/Contents/MacOS/PolePole Dev" >/dev/null 2>&1; then
  echo "error: PolePole Dev が起動していない" >&2
  exit 1
fi
