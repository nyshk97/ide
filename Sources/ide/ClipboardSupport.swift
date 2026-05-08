import AppKit
import GhosttyKit

// MARK: - 書き込み（コピー）

/// Ghostty が「コピーして」と要求してきたとき呼ばれる。
/// content は mime/data ペアの配列で、text/plain を優先採用する。
func ghosttyWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    length: Int,
    confirm: Bool
) {
    guard let content, length > 0 else { return }
    let buffer = UnsafeBufferPointer(start: content, count: length)

    var fallback: String?
    for item in buffer {
        guard let dataPtr = item.data else { continue }
        let value = String(cString: dataPtr)
        if let mimePtr = item.mime {
            let mime = String(cString: mimePtr)
            if mime.hasPrefix("text/plain") {
                writePasteboard(value, location: location)
                return
            }
        }
        if fallback == nil {
            fallback = value
        }
    }
    if let fallback {
        writePasteboard(fallback, location: location)
    }
}

// MARK: - 読み込み（ペースト）

/// Ghostty が「ペーストする内容を教えて」と要求してきたとき呼ばれる。
/// 同期で完了させ、`ghostty_surface_complete_clipboard_request` で内容を返す。
/// 戻り値の意味: 確認ダイアログが必要か（true なら confirm_read_clipboard_cb 経由で完了させる）。
/// PoC では確認なしで即完了させる。
func ghosttyReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    location: ghostty_clipboard_e,
    state: UnsafeMutableRawPointer?
) -> Bool {
    let pb = pasteboard(for: location)
    let content = pb.string(forType: .string) ?? ""

    // TODO step5（複数タブ）: 現在はグローバル surface を使う雑実装。
    //                       本来は userdata or state から該当 surface を解決する。
    guard let surface = GhosttyManager.shared.activeSurface else { return false }

    return content.withCString { ptr in
        ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
        return true
    }
}

/// 確認ダイアログ経由のペースト承認用。PoC では使わないので no-op。
func ghosttyConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    content: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    // 何もしない
}

// MARK: - ヘルパ

private func writePasteboard(_ string: String, location: ghostty_clipboard_e) {
    let pb = pasteboard(for: location)
    pb.clearContents()
    pb.setString(string, forType: .string)
}

private func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
    // macOS には X11 風の "selection" クリップボードはないため一般 PB に集約。
    // 必要なら NSPasteboard(name: .find) 等への切替も検討可。
    return .general
}
