import AppKit
import Foundation

/// ユーザーが変更可能な 3 つのショートカットを表す。
/// MRUKeyMonitor が固定のキーコード直書きから ShortcutsStore.shared.matches(_:_:) 経由に置き換わる。
enum ShortcutAction: String, CaseIterable, Codable {
    case mruOverlay
    case diffOverlay
    case toggleSidebar
    case setPaneLayoutSingle
    case setPaneLayoutSplit
    case setPaneLayoutHorizontal
    case setPaneLayoutFour

    var label: String {
        switch self {
        case .mruOverlay:            return "MRU project switcher"
        case .diffOverlay:           return "Diff overlay"
        case .toggleSidebar:         return "Show/Hide Project Sidebar"
        case .setPaneLayoutSingle:   return "1 pane"
        case .setPaneLayoutSplit:    return "Split vertically (top/bottom)"
        case .setPaneLayoutHorizontal: return "Split horizontally (left/right)"
        case .setPaneLayoutFour:     return "4-pane grid"
        }
    }

    /// 初期値。Ctrl+M / Cmd+D / Cmd+S / Cmd+Opt+1〜4。
    /// PolePole は編集機能を持たないので Cmd+S (save) が空いている。
    static let defaults: [ShortcutAction: KeyCombo] = [
        .mruOverlay:              KeyCombo(keyCode: 46, modifiers: NSEvent.ModifierFlags.control.rawValue,                          keyLabel: "M"),
        .diffOverlay:             KeyCombo(keyCode: 2,  modifiers: NSEvent.ModifierFlags.command.rawValue,                          keyLabel: "D"),
        .toggleSidebar:           KeyCombo(keyCode: 1,  modifiers: NSEvent.ModifierFlags.command.rawValue,                          keyLabel: "S"),
        .setPaneLayoutSingle:     KeyCombo(keyCode: 18, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "1"),
        .setPaneLayoutSplit:      KeyCombo(keyCode: 19, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "2"),
        .setPaneLayoutHorizontal: KeyCombo(keyCode: 20, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "3"),
        .setPaneLayoutFour:       KeyCombo(keyCode: 21, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "4"),
    ]
}

/// 修飾キー + 物理キーの 1 ストローク表現。
/// 録音時に `keyLabel` を `event.charactersIgnoringModifiers` または特殊キー名から決めて保存する。
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue`。primary modifier (Cmd/Ctrl/Opt/Shift) のみ。
    /// 矢印・テンキー由来の `.numericPad` / `.function` は from(event:) で除去済みなので、
    /// 比較や永続化では一切意識しなくてよい。
    var modifiers: UInt
    /// 表示用ラベル（例: "M", "↓", "Esc"）。録音時に決定。
    var keyLabel: String

    /// `NSEvent.ModifierFlags` で比較するときに使うマスク。Shift 単独は他で除外。
    static let primaryMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.primaryMask)
    }

    /// 修飾キー（Cmd/Ctrl/Opt のいずれか）が 1 つでも含まれているか。Shift 単独は無効扱い。
    var hasPrimaryModifier: Bool {
        let primary: NSEvent.ModifierFlags = [.command, .control, .option]
        return !modifierFlags.intersection(primary).isEmpty
    }

    func matches(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(Self.primaryMask)
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
    /// 矢印・テンキー由来の `.numericPad` / `.function` は保存しない（primary modifier のみ）。
    /// これで「ユーザーが矢印キーで録音した combo」と「実行時の矢印 keyDown」が一致するようになる。
    static func from(event: NSEvent) -> KeyCombo {
        let mods = event.modifierFlags.intersection(primaryMask)
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

/// 永続化先 `~/Library/Application Support/{polepole,polepole-dev}/shortcuts.json`。
/// schemaVersion: 1。MainActor に閉じる（ProjectsModel と同じ流儀）。
@MainActor
final class ShortcutsStore: ObservableObject {
    static let shared = ShortcutsStore()

    @Published private(set) var bindings: [ShortcutAction: KeyCombo]

    /// Settings 画面でショートカット録音中かどうか。
    /// MRUKeyMonitor は `addLocalMonitorForEvents` で keyDown をプロセス全体から横取りするため、
    /// 録音中にユーザーが押した固定ショートカット (Cmd+P 等) が MRUKeyMonitor に消費されてしまい、
    /// Settings の録音 monitor に届かない＝衝突警告が出ない問題があった。
    /// 録音中は MRUKeyMonitor 側でこのフラグを見て素通りさせる。
    @Published var isRecordingShortcut: Bool = false

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

/// 衝突検出用に PolePole 内に実装済みの固定ショートカット一覧。
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
        Entry(keyCode: 13, modifiers: .command,                 label: "Cmd+W (Close Tab / Close Diff)"),
        Entry(keyCode: 3,  modifiers: .command,                 label: "Cmd+F (In-file Search)"),
        Entry(keyCode: 15, modifiers: .command,                 label: "Cmd+R (Rescan / Diff Reload)"),
        Entry(keyCode: 8,  modifiers: .command,                 label: "Cmd+C (Copy Path in Overlay)"),
        Entry(keyCode: 5,  modifiers: .command,                 label: "Cmd+G (Next Match)"),
        Entry(keyCode: 5,  modifiers: [.command, .shift],       label: "Cmd+Shift+G (Previous Match)"),
        Entry(keyCode: 31, modifiers: [.command, .option],      label: "Cmd+Opt+O (Open in Editor)"),
        Entry(keyCode: 37, modifiers: [.command, .shift],       label: "Cmd+Shift+L (Open Log Folder)"),
        Entry(keyCode: 45, modifiers: .control,                 label: "Ctrl+N (Overlay Down)"),
        Entry(keyCode: 35, modifiers: .control,                 label: "Ctrl+P (Overlay Up)"),
        Entry(keyCode: 124, modifiers: [.command, .option],     label: "Cmd+Opt+→ (Next Tab)"),
        Entry(keyCode: 123, modifiers: [.command, .option],     label: "Cmd+Opt+← (Previous Tab)"),
        Entry(keyCode: 126, modifiers: [.command, .option],     label: "Cmd+Opt+↑ (Focus Top Pane)"),
        Entry(keyCode: 125, modifiers: [.command, .option],     label: "Cmd+Opt+↓ (Focus Bottom Pane)"),
        Entry(keyCode: 126, modifiers: [.command, .shift, .option], label: "Cmd+Shift+Opt+↑ (Move Tab to Top Pane)"),
        Entry(keyCode: 125, modifiers: [.command, .shift, .option], label: "Cmd+Shift+Opt+↓ (Move Tab to Bottom Pane)"),
    ]

    static func conflict(for combo: KeyCombo) -> String? {
        // 矢印キーで録音した combo は、修正後の from(event:) で .numericPad/.function を捨てているが、
        // 旧バージョンで保存された combo にはそれらが残っている可能性がある。
        // 両側を primary modifier に正規化して比較する。
        let lhs = combo.modifierFlags.intersection(KeyCombo.primaryMask)
        for e in all {
            let rhs = e.modifiers.intersection(KeyCombo.primaryMask)
            if e.keyCode == combo.keyCode && lhs == rhs {
                return e.label
            }
        }
        return nil
    }
}
