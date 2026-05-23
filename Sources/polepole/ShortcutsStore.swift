import AppKit
import Foundation

/// ユーザーが変更可能な 3 つのショートカットを表す。
/// MRUKeyMonitor が固定のキーコード直書きから ShortcutsStore.shared.matches(_:_:) 経由に置き換わる。
enum ShortcutAction: String, CaseIterable, Codable {
    case mruOverlay
    case diffOverlay
    case togglePreview

    var label: String {
        switch self {
        case .mruOverlay:    return "MRU project switcher"
        case .diffOverlay:   return "Diff overlay"
        case .togglePreview: return "Toggle file tree / preview"
        }
    }

    /// 初期値。CLAUDE.md 既定の Ctrl+M / Cmd+D / Cmd+J。
    static let defaults: [ShortcutAction: KeyCombo] = [
        .mruOverlay:    KeyCombo(keyCode: 46, modifiers: NSEvent.ModifierFlags.control.rawValue, keyLabel: "M"),
        .diffOverlay:   KeyCombo(keyCode: 2,  modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "D"),
        .togglePreview: KeyCombo(keyCode: 38, modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "J"),
    ]
}

/// 修飾キー + 物理キーの 1 ストローク表現。
/// 録音時に `keyLabel` を `event.charactersIgnoringModifiers` または特殊キー名から決めて保存する。
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue`。device-independent な flag のみ。
    var modifiers: UInt
    /// 表示用ラベル（例: "M", "↓", "Esc"）。録音時に決定。
    var keyLabel: String

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask)
    }

    /// 修飾キー（Cmd/Ctrl/Opt のいずれか）が 1 つでも含まれているか。Shift 単独は無効扱い。
    var hasPrimaryModifier: Bool {
        let primary: NSEvent.ModifierFlags = [.command, .control, .option]
        return !modifierFlags.intersection(primary).isEmpty
    }

    func matches(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == keyCode && mods == modifierFlags
    }

    /// "⌃M", "⌘D" のような UI 表示文字列。
    var display: String {
        var s = ""
        let m = modifierFlags
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        s += keyLabel
        return s
    }

    /// NSEvent から KeyCombo を作る。
    static func from(event: NSEvent) -> KeyCombo {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyCombo(
            keyCode: event.keyCode,
            modifiers: mods.rawValue,
            keyLabel: labelFor(keyCode: event.keyCode, event: event)
        )
    }

    /// 特殊キーは固定テーブル、それ以外は charactersIgnoringModifiers を upper case。
    static func labelFor(keyCode: UInt16, event: NSEvent) -> String {
        if let s = specialKeyNames[keyCode] { return s }
        let raw = event.charactersIgnoringModifiers ?? ""
        let upper = raw.uppercased()
        return upper.isEmpty ? "Key\(keyCode)" : upper
    }

    private static let specialKeyNames: [UInt16: String] = [
        53: "Esc",
        36: "Return",
        76: "Enter",
        48: "Tab",
        49: "Space",
        51: "Delete",
        117: "Fwd Del",
        125: "↓",
        126: "↑",
        123: "←",
        124: "→",
        116: "Page Up",
        121: "Page Down",
        115: "Home",
        119: "End",
        122: "F1", 120: "F2", 99: "F3",  118: "F4",
        96:  "F5", 97:  "F6", 98: "F7",  100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// 永続化先 `~/Library/Application Support/{ide,ide-dev}/shortcuts.json`。
/// schemaVersion: 1。MainActor に閉じる（ProjectsModel と同じ流儀）。
@MainActor
final class ShortcutsStore: ObservableObject {
    static let shared = ShortcutsStore()

    @Published private(set) var bindings: [ShortcutAction: KeyCombo]

    private init() {
        self.bindings = Self.loadFromDisk() ?? ShortcutAction.defaults
    }

    func combo(for action: ShortcutAction) -> KeyCombo {
        bindings[action] ?? ShortcutAction.defaults[action]!
    }

    /// MRUKeyMonitor 側からはこれだけ呼ぶ。
    func matches(_ event: NSEvent, _ action: ShortcutAction) -> Bool {
        combo(for: action).matches(event)
    }

    /// MRU overlay の確定判定（Ctrl 等のキーが離れた瞬間）。
    /// バインドの全修飾キーが現 modifier から外れたら true。
    func shouldCommitMRU(currentModifiers: NSEvent.ModifierFlags) -> Bool {
        let needed = combo(for: .mruOverlay).modifierFlags
        let primary: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let neededPrimary = needed.intersection(primary)
        let current = currentModifiers.intersection(.deviceIndependentFlagsMask)
        return current.intersection(neededPrimary) != neededPrimary
    }

    func setCombo(_ combo: KeyCombo, for action: ShortcutAction) {
        bindings[action] = combo
        save()
    }

    func resetOne(_ action: ShortcutAction) {
        bindings[action] = ShortcutAction.defaults[action]
        save()
    }

    func resetAll() {
        bindings = ShortcutAction.defaults
        save()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var bindings: [String: KeyCombo]
    }

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(AppPaths.subdirName, isDirectory: true)
            .appendingPathComponent("shortcuts.json")
    }

    private static func loadFromDisk() -> [ShortcutAction: KeyCombo]? {
        let url = storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snap.schemaVersion == 1 else {
                Logger.shared.debug("[shortcuts] unknown schemaVersion=\(snap.schemaVersion)")
                return nil
            }
            var result = ShortcutAction.defaults
            for (k, v) in snap.bindings {
                if let action = ShortcutAction(rawValue: k) {
                    result[action] = v
                }
            }
            return result
        } catch {
            Logger.shared.debug("[shortcuts] load failed: \(error)")
            return nil
        }
    }

    private func save() {
        let url = Self.storageURL
        let bindings = self.bindings
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snap = Snapshot(
                schemaVersion: 1,
                bindings: Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snap)
            try data.write(to: url, options: [.atomic])
        } catch {
            Logger.shared.debug("[shortcuts] save failed: \(error)")
        }
    }
}

/// 衝突検出用に IDE 内に実装済みの固定ショートカット一覧。
/// 設定画面の警告表示に使う（保存は許可、警告のみ）。
enum FixedShortcuts {
    struct Entry {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let label: String
    }

    static let all: [Entry] = [
        Entry(keyCode: 35, modifiers: .command,                 label: "Cmd+P (Quick Search)"),
        Entry(keyCode: 3,  modifiers: [.command, .shift],       label: "Cmd+Shift+F (Full Search)"),
        Entry(keyCode: 17, modifiers: .command,                 label: "Cmd+T (New Terminal Tab)"),
        Entry(keyCode: 13, modifiers: .command,                 label: "Cmd+W (Close Tab)"),
        Entry(keyCode: 3,  modifiers: .command,                 label: "Cmd+F (In-file Search)"),
        Entry(keyCode: 15, modifiers: .command,                 label: "Cmd+R (Rescan / Diff Reload)"),
        Entry(keyCode: 8,  modifiers: .command,                 label: "Cmd+C (Copy Path in Overlay)"),
        Entry(keyCode: 5,  modifiers: .command,                 label: "Cmd+G (Next Match)"),
        Entry(keyCode: 5,  modifiers: [.command, .shift],       label: "Cmd+Shift+G (Previous Match)"),
        Entry(keyCode: 31, modifiers: [.command, .option],      label: "Cmd+Opt+O (Open in Editor)"),
        Entry(keyCode: 37, modifiers: [.command, .shift],       label: "Cmd+Shift+L (Open Log Folder)"),
        Entry(keyCode: 45, modifiers: .control,                 label: "Ctrl+N (Overlay Down)"),
        Entry(keyCode: 35, modifiers: .control,                 label: "Ctrl+P (Overlay Up)"),
    ]

    static func conflict(for combo: KeyCombo) -> String? {
        for e in all {
            if e.keyCode == combo.keyCode && e.modifiers == combo.modifierFlags {
                return e.label
            }
        }
        return nil
    }
}
