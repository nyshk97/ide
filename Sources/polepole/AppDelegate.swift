import AppKit

/// メインメニューの不要項目を実行時に整理する。SwiftUI の `CommandGroup`
/// では消せないもの（AppKit が menu open 時に足す Edit > AutoFill / Start Dictation /
/// Emoji & Symbols、Help の検索ボックス、Window > Fill/Center 等）と、空になった
/// File / Window メニュー自体の削除を担当する。
@MainActor
final class IdeAppDelegate: NSObject, NSApplicationDelegate {
    /// Edit メニュー末尾で AppKit が動的に足してくる不要項目。menu open ごとに
    /// 復活するので、毎回 NSMenuDelegate.menuNeedsUpdate で消す。
    private static let editMenuItemsToStrip: Set<String> = [
        "AutoFill",
        "Start Dictation…",
        "Start Dictation",
        "Emoji & Symbols",
    ]

    private weak var editMenuRef: NSMenu?

    /// sanitize 中の再入を防ぐ。removeItem は副次的な通知を発火するため、
    /// didUpdate ループで無限に走り得る。
    private var isSanitizing = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // タブ機能を切る。これで View > Show Tab Bar / Show All Tabs と
        // Window > Show Previous/Next Tab / Move Tab to New Window / Merge All Windows が消える。
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sanitizeMainMenu()
        // AppKit はフルスクリーン遷移や NSOpenPanel / NSSavePanel 等の system panel
        // 表示時にも Window / Help メニューを再追加してくる。observer をいくら積んでも
        // 抜け道が残るので、NSApplication.didUpdate（event loop の各 iteration で発火）
        // で毎回 sanitize し直すアプローチを取る。差分が無い時は no-op になる。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sanitizeMainMenu()
            }
        }
    }

    private func sanitizeMainMenu() {
        guard !isSanitizing else { return }
        guard let main = NSApp.mainMenu else { return }
        isSanitizing = true
        defer { isSanitizing = false }

        // File / Window / Help メニューは中身を全部消すか、検索ボックスを
        // SwiftUI/AppKit 両方から消す確実な手段が無いため、まるごと削除する。
        // 「ログファイルを開く」は IDE Dev メニューに移している。
        for title in ["File", "Window", "Help"] {
            if let item = main.items.first(where: { $0.submenu?.title == title }) {
                main.removeItem(item)
            }
        }

        // Edit メニュー: AutoFill / Start Dictation / Emoji & Symbols を都度削除する。
        if let editMenu = main.items.first(where: { $0.submenu?.title == "Edit" })?.submenu {
            if editMenuRef !== editMenu {
                editMenuRef = editMenu
                editMenu.delegate = self
            }
            stripEditMenu(editMenu)
        }
    }

    private func stripEditMenu(_ menu: NSMenu) {
        menu.items
            .filter { Self.editMenuItemsToStrip.contains($0.title) }
            .forEach { menu.removeItem($0) }
        cleanupSeparators(menu)
    }

    /// 連続セパレーターと先頭/末尾のセパレーターを除去する。
    private func cleanupSeparators(_ menu: NSMenu) {
        var changed = true
        while changed {
            changed = false
            for i in stride(from: menu.items.count - 1, through: 0, by: -1) {
                let item = menu.items[i]
                guard item.isSeparatorItem else { continue }
                if i == 0 || i == menu.items.count - 1 {
                    menu.removeItem(item)
                    changed = true
                } else if menu.items[i - 1].isSeparatorItem {
                    menu.removeItem(item)
                    changed = true
                }
            }
        }
    }
}

extension IdeAppDelegate: NSMenuDelegate {
    /// AppKit は menu が開かれる直前に AutoFill / Dictation / Emoji を
    /// 再追加するので、ここで毎回そぎ落とす。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === editMenuRef {
            stripEditMenu(menu)
        }
    }
}
