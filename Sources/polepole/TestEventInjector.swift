import AppKit

#if DEBUG
/// VERIFY 用のイベント注入フック（Debug ビルド限定）。
///
/// `POLEPOLE_TEST_EVENT_FILE=<path>` を付けて起動すると、そのファイル（JSONL）への追記を監視し、
/// 1 行 1 コマンドとして処理する。キー入力は `NSEvent.keyEvent` で合成して `NSApp.postEvent` に
/// 積むので、`sendEvent` → `MRUKeyMonitor`（local monitor）→ responder chain（Ghostty / TextField）
/// と**本物のキー入力と同じ経路**を通る。osascript の補助アクセス権限が要らないので、
/// PolePole 内の Claude Code からでもキー操作の検証を自動化できる。
///
/// コマンド:
/// - `{"type":"key","keyCode":36}`                          … 1 キー押下（keyDown + keyUp）。
///   `"mods":["cmd","shift","ctrl","opt"]` で修飾、`"chars":"\r"` で characters を明示（省略時は keyCode から補完）
/// - `{"type":"text","text":"echo hi"}`                     … ASCII 文字列を 1 文字ずつキー押下として送る
/// - `{"type":"focus","target":"terminal"|"preview"|"find"}` … first responder をアクティブ端末 / プレビューペイン /
///   検索バー入力欄（Cmd+F 相当）へ移す
///
/// 使い方: `EV=/tmp/ev.jsonl; : > "$EV"; open -n "$APP" --env POLEPOLE_TEST_EVENT_FILE="$EV" ...` の後、
/// `echo '{"type":"key","keyCode":36}' >> "$EV"`。処理した行は `[test-event]` として Logger に出る。
@MainActor
enum TestEventInjector {
    private static var source: DispatchSourceFileSystemObject?
    private static var handle: FileHandle?
    private static var pending = Data()

    static func installIfRequested() {
        guard source == nil,
              let path = ProcessInfo.processInfo.environment["POLEPOLE_TEST_EVENT_FILE"], !path.isEmpty
        else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forReadingAtPath: path) else {
            Logger.shared.warn("[test-event] cannot open \(path)")
            return
        }
        handle = h
        // 起動前に書かれていた分は無視して末尾から読む
        h.seekToEndOfFile()
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: h.fileDescriptor, eventMask: [.write, .extend], queue: .main
        )
        src.setEventHandler { drain() }
        src.resume()
        source = src
        Logger.shared.debug("[test-event] watching \(path)")
    }

    private static func drain() {
        guard let handle else { return }
        pending.append(handle.readDataToEndOfFile())
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String
            else {
                Logger.shared.warn("[test-event] unparsable line: \(String(decoding: line, as: UTF8.self))")
                continue
            }
            handleCommand(type: type, obj: obj)
        }
    }

    private static func handleCommand(type: String, obj: [String: Any]) {
        switch type {
        case "key":
            guard let code = obj["keyCode"] as? Int else { return }
            let mods = flags(from: obj["mods"] as? [String] ?? [])
            let chars = obj["chars"] as? String ?? defaultChars(for: UInt16(code), mods: mods)
            postKey(keyCode: UInt16(code), chars: chars, mods: mods)
            Logger.shared.debug("[test-event] key code=\(code) mods=\(mods.rawValue)")
        case "text":
            guard let text = obj["text"] as? String else { return }
            for ch in text {
                guard let (code, shift) = keyCode(for: ch) else {
                    Logger.shared.warn("[test-event] no keyCode for \(ch), skipped")
                    continue
                }
                postKey(keyCode: code, chars: String(ch), mods: shift ? .shift : [])
            }
            Logger.shared.debug("[test-event] text \(text.count) chars")
        case "focus":
            let target = obj["target"] as? String ?? ""
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            switch target {
            case "terminal":
                if let v = ProjectsModel.shared.activeWorkspace?.activePane.activeTab?.realNSView {
                    window.makeFirstResponder(v)
                }
            case "preview":
                if let root = window.contentView, let v = findPreviewHost(in: root) {
                    window.makeFirstResponder(v)
                }
            case "find":
                ProjectsModel.shared.activePreview?.showFindBar()
            default:
                break
            }
            // SwiftUI の @FocusState（"find"）は非同期に反映されるので、落ち着いた後の responder も出す
            let describe = { window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil" }
            Logger.shared.debug("[test-event] focus \(target) -> firstResponder=\(describe())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Logger.shared.debug("[test-event] focus \(target) settled -> firstResponder=\(describe())")
            }
        default:
            Logger.shared.warn("[test-event] unknown type \(type)")
        }
    }

    private static func postKey(keyCode: UInt16, chars: String, mods: NSEvent.ModifierFlags) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let location = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        let base = chars.lowercased()
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(
                with: kind, location: location, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: base,
                isARepeat: false, keyCode: keyCode
            ) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    private static func flags(from names: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for n in names {
            switch n {
            case "cmd", "command": f.insert(.command)
            case "shift": f.insert(.shift)
            case "ctrl", "control": f.insert(.control)
            case "opt", "option", "alt": f.insert(.option)
            default: break
            }
        }
        return f
    }

    private static func defaultChars(for keyCode: UInt16, mods: NSEvent.ModifierFlags) -> String {
        switch keyCode {
        case 36, 76: return "\r"
        case 53: return "\u{1b}"
        case 48: return "\t"
        case 51: return "\u{7f}"
        case 49: return " "
        default:
            if let ch = table.first(where: { $0.value == keyCode })?.key {
                return mods.contains(.shift) ? String(ch).uppercased() : String(ch)
            }
            return ""
        }
    }

    /// ASCII → US キーボードの keyCode。大文字は同じ keyCode + shift。
    private static func keyCode(for ch: Character) -> (UInt16, Bool)? {
        if let code = table[ch] { return (code, false) }
        let lower = Character(ch.lowercased())
        if ch.isUppercase, let code = table[lower] { return (code, true) }
        if let code = shifted[ch] { return (code, true) }
        return nil
    }

    private static let table: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]
    private static let shifted: [Character: UInt16] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28, "(": 25, ")": 29,
        "_": 27, "+": 24, "{": 33, "}": 30, "|": 42, ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44, "~": 50,
    ]

    private static func findPreviewHost(in view: NSView) -> NSView? {
        if view is PreviewFocusHostingMarker { return view }
        for sub in view.subviews {
            if let hit = findPreviewHost(in: sub) { return hit }
        }
        return nil
    }
}
#endif
