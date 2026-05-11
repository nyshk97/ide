#!/usr/bin/env bash
# ide のフロントウィンドウだけをキャプチャして指定パスに保存。
#
# osascript（System Events 経由 = 補助アクセス権限が必要）は使わず、
# CGWindowList でウィンドウ ID を引いて `screencapture -l` に渡す。
# これで「アクセシビリティ」権限の毎回ポップアップを回避できる
# （`screencapture` 自体は「画面収録」権限が要る点は変わらない）。
#
# ウィンドウ ID を取れない / 権限が無いときはメイン画面全体を撮ってフォールバックする。
#
# 使い方: scripts/ide-screenshot.sh <output_path>
set -euo pipefail

OUT="${1:-/tmp/ide-screenshot.png}"

# Debug ビルドのプロセス名は "IDE Dev"、Release は "IDE"。両方を候補にして、
# 通常レイヤー(0)・対象オーナーのウィンドウのうち面積が最大のものを選ぶ。
WINID=$(/usr/bin/swift - <<'SWIFT' 2>/dev/null || true
import CoreGraphics
import Foundation
let owners: Set<String> = ["IDE Dev", "IDE"]
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
var best: (num: Int, area: CGFloat)? = nil
for w in list {
    guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
    guard let owner = w[kCGWindowOwnerName as String] as? String, owners.contains(owner) else { continue }
    guard let num = w[kCGWindowNumber as String] as? Int else { continue }
    let b = w[kCGWindowBounds as String] as? [String: CGFloat]
    let area = (b?["Width"] ?? 0) * (b?["Height"] ?? 0)
    if best == nil || area > best!.area { best = (num, area) }
}
if let b = best { print(b.num); exit(0) }
exit(1)
SWIFT
)

if [[ -n "${WINID:-}" ]] && screencapture -x -o -l"$WINID" "$OUT" 2>/dev/null; then
  echo "$OUT"
  exit 0
fi

echo "warn: IDE のウィンドウを直接撮れなかった。メイン画面全体を撮影する" >&2
screencapture -x "$OUT"
echo "$OUT"
