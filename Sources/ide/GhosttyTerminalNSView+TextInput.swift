import AppKit
import GhosttyKit

// MARK: - NSTextInputClient（IME・日本語入力対応）

extension GhosttyTerminalNSView: @preconcurrency NSTextInputClient {

    // MARK: 状態問い合わせ

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        markedText.length > 0
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        markedSelectedRange
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // 属性付き marked text には今は対応しない（カーソル位置・色等）
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // Ghostty 側にバッファ参照 API がないので nil を返す
        nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    // MARK: テキスト入力

    /// IME が確定した文字列を渡してくる経路。
    /// keyDown 中であれば accumulator に貯めて後段で処理し、
    /// それ以外（音声入力等）であれば surface に直接送る。
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String: text = s
        case let s as NSAttributedString: text = s.string
        default: return
        }

        markedText = NSMutableAttributedString()
        markedSelectedRange = NSRange(location: 0, length: 0)

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }

        guard let s = surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(s, ptr, UInt(text.utf8.count))
        }
    }

    /// 未確定（preedit）テキスト更新。
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let attributed: NSAttributedString
        switch string {
        case let s as String: attributed = NSAttributedString(string: s)
        case let s as NSAttributedString: attributed = s
        default: return
        }

        markedText = NSMutableAttributedString(attributedString: attributed)
        markedSelectedRange = selectedRange
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        markedSelectedRange = NSRange(location: 0, length: 0)
    }

    /// IME ポップアップの位置決め。Ghostty が知っているカーソル位置を画面座標に変換して返す。
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let s = surface, let window = window else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(s, &x, &y, &w, &h)
        // Ghostty 側は左上原点。NSView は左下原点なので Y を反転（h を引いてベースラインに揃える）
        let viewPoint = NSPoint(x: x, y: bounds.height - y - h)
        let windowPoint = convert(viewPoint, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        return NSRect(x: screenPoint.x, y: screenPoint.y, width: w, height: h)
    }
}

// MARK: - Preedit ヘルパ

extension GhosttyTerminalNSView {
    func syncPreedit() {
        guard let s = surface else { return }
        let preedit = markedText.string
        if preedit.isEmpty {
            ghostty_surface_preedit(s, nil, 0)
        } else {
            preedit.withCString { ptr in
                ghostty_surface_preedit(s, ptr, UInt(preedit.utf8.count))
            }
        }
    }
}
