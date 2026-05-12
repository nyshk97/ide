import AppKit
import GhosttyKit
import UniformTypeIdentifiers

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

    // テキストが入っていればそれを優先（通常のペースト）。
    // 空文字列ではなく nil の場合だけ画像にフォールバックする。
    let content: String
    if let text = pb.string(forType: .string), !text.isEmpty {
        content = text
    } else if let imagePath = saveClipboardImageIfNeeded(from: pb) {
        // 画像がクリップボードにあれば cache ディレクトリに保存し、シェルエスケープしたパスを返す。
        // Claude Code はパスを画像として認識してくれる。
        content = imagePath
    } else {
        content = ""
    }

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

// MARK: - 画像ペースト対応

/// クリップボード画像の保存先。`~/Library/Caches/{ide,ide-dev}/clipboard/`。
private var clipboardImageDirectory: URL {
    AppPaths.cacheDirectory.appendingPathComponent("clipboard", isDirectory: true)
}

/// 起動時に呼ぶ。クリップボード画像キャッシュのうち 1 日以上前のものを削除する。
/// 画像には個人情報が入りやすいので溜め込まない。
func cleanupOldClipboardImages() {
    let fm = FileManager.default
    let dir = clipboardImageDirectory
    guard let entries = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    for url in entries {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let mtime, mtime < cutoff {
            try? fm.removeItem(at: url)
        }
    }
}

/// クリップボードに画像があれば cache ディレクトリに書き出してシェルエスケープ済みのパスを返す。
/// Claude Code は `~/Library/Caches/ide/clipboard/clipboard-...png` のようなパスを画像として認識する。
private func saveClipboardImageIfNeeded(from pb: NSPasteboard) -> String? {
    guard let (data, ext) = clipboardImageRepresentation(in: pb) else { return nil }

    let dir = clipboardImageDirectory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let timestamp = formatter.string(from: Date())
    let filename = "clipboard-\(timestamp)-\(UUID().uuidString.prefix(8)).\(ext)"
    let url = dir.appendingPathComponent(filename)

    do {
        try data.write(to: url)
    } catch {
        PocLog.write("[clipboard] image write failed: \(error.localizedDescription)")
        return nil
    }

    return ShellEscaper.escape(url.path)
}

/// クリップボードから画像データと拡張子を取り出す。
/// PNG をそのまま使えるならそれを優先し、ダメなら NSImage 経由で PNG に変換する。
private func clipboardImageRepresentation(in pb: NSPasteboard) -> (Data, String)? {
    let types = pb.types ?? []

    if let pngData = pb.data(forType: .png) {
        return (pngData, "png")
    }

    for type in types {
        guard type != .png, type != .tiff,
              let utType = UTType(type.rawValue),
              utType.conforms(to: .image),
              let data = pb.data(forType: type),
              let ext = utType.preferredFilenameExtension,
              !ext.isEmpty else { continue }
        return (data, ext)
    }

    // TIFF / その他のフォーマットを NSImage で読み直して PNG にする
    guard hasImageData(in: pb),
          let image = NSImage(pasteboard: pb),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        return nil
    }
    return (png, "png")
}

private func hasImageData(in pb: NSPasteboard) -> Bool {
    let types = pb.types ?? []
    if types.contains(.tiff) || types.contains(.png) { return true }
    return types.contains { type in
        guard let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .image)
    }
}
