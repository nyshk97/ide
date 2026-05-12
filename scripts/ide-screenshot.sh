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

# Debug ビルドのプロセス名は "IDE Dev"、Release（Brew 配布版）は "IDE"。
# 開発中は両方が同時に起動していることが多い（Brew 版の中で Claude Code を動かしつつ
# Debug 版をビルドして検証する）。なので「IDE Dev のウィンドウがあればそれを優先」し、
# 無いときだけ "IDE" を見る。同じオーナーの中では面積が最大のウィンドウを選ぶ。
WINID=$(/usr/bin/swift - <<'SWIFT' 2>/dev/null || true
import CoreGraphics
import Foundation
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
func largestWindow(owner target: String) -> Int? {
    var best: (num: Int, area: CGFloat)? = nil
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
        guard (w[kCGWindowOwnerName as String] as? String) == target else { continue }
        guard let num = w[kCGWindowNumber as String] as? Int else { continue }
        let b = w[kCGWindowBounds as String] as? [String: CGFloat]
        let area = (b?["Width"] ?? 0) * (b?["Height"] ?? 0)
        if best == nil || area > best!.area { best = (num, area) }
    }
    return best?.num
}
if let n = largestWindow(owner: "IDE Dev") ?? largestWindow(owner: "IDE") {
    print(n)
    exit(0)
}
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
