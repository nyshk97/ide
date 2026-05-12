import AppKit

/// アプリ全体で Ctrl+M / Esc / Ctrl 離しを最優先で捕捉して `ProjectsModel` に届ける。
///
/// `NSEvent.addLocalMonitorForEvents` は AppKit/SwiftUI の通常パイプラインより前に呼ばれるので、
/// Ghostty NSView の performKeyEquivalent や TUI の中（vim/claude）でも IDE が確実に握れる。
@MainActor
enum MRUKeyMonitor {
    private static var keyDownMonitor: Any?
    private static var flagsMonitor: Any?

    /// 起動時に 1 回呼ぶ。重複登録は無視。
    static func install() {
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyDown(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    /// true を返したら event を「消費した」扱い（モニターが nil を返してパイプラインに流さない）。
    @MainActor
    private static func handleKeyDown(_ event: NSEvent) -> Bool {
        let model = ProjectsModel.shared
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ctrl+M: オーバーレイ起動 / 次の候補へサイクル。
        // chars だと Ctrl+letter で CR(\r) にマップされるため keyCode で判定（46 = M）。
        if mods == .control, event.keyCode == 46 {
            model.openOrCycleMRUOverlay()
            return true
        }

        // オーバーレイ表示中の Esc: キャンセル
        if model.mruOverlay != nil, event.keyCode == 53 {  // 53 = Esc
            model.cancelMRUOverlay()
            return true
        }

        // Cmd+P: クイック検索オーバーレイ起動。
        if mods == .command, event.keyCode == 35 {  // 35 = P
            model.openQuickSearch()
            return true
        }

        // Cmd+Shift+F: 全文検索オーバーレイ起動。
        if mods == [.command, .shift], event.keyCode == 3 {  // 3 = F
            model.openFullSearch()
            return true
        }

        // Cmd+J: 中央ペインを ツリー ↔ プレビュー でトグル。
        if mods == .command, event.keyCode == 38 {  // 38 = J
            model.togglePreview()
            return true
        }

        // Cmd+R: ファイルツリーにフォーカスがあるとき再スキャン（toolbar の 🔄 ボタンと同等）。
        if mods == .command, event.keyCode == 15, model.fileTreeFocused {  // 15 = R
            model.reloadActiveFileTree()
            return true
        }

        // クイック検索表示中のキー操作
        if model.quickSearchVisible {
            // Cmd+C: 選択中エントリの相対パスをコピー（選択が無ければ素通り）
            if mods == .command, event.keyCode == 8 {  // 8 = C
                if let path = model.quickSearchSelectedPath() {
                    copyPath(path)
                    return true
                }
            }
            switch event.keyCode {
            case 53:  // Esc
                model.closeQuickSearch()
                return true
            case 125:  // Down
                model.quickSearchMoveSelection(1)
                return true
            case 126:  // Up
                model.quickSearchMoveSelection(-1)
                return true
            default:
                break
            }
        }

        // 全文検索表示中のキー操作
        if model.fullSearchVisible {
            // Cmd+C: 選択中ヒットの相対パスをコピー（選択が無ければ素通り）
            if mods == .command, event.keyCode == 8 {  // 8 = C
                if let path = model.fullSearchSelectedPath() {
                    copyPath(path)
                    return true
                }
            }
            switch event.keyCode {
            case 53:  // Esc
                model.closeFullSearch()
                return true
            case 125:  // Down
                model.fullSearchMoveSelection(1)
                return true
            case 126:  // Up
                model.fullSearchMoveSelection(-1)
                return true
            default:
                break
            }
        }

        return false
    }

    /// パス文字列を一般ペーストボードへ。簡単な確認 toast も出す。
    @MainActor
    private static func copyPath(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
        ErrorBus.shared.notify("パスをコピーしました: \(path)", kind: .info)
    }

    /// Ctrl 離しで確定。.flagsChanged は modifier の変化通知。
    @MainActor
    private static func handleFlagsChanged(_ event: NSEvent) {
        let model = ProjectsModel.shared
        guard model.mruOverlay != nil else { return }
        // Ctrl が外れたら確定
        if !event.modifierFlags.contains(.control) {
            model.commitMRUOverlay()
        }
    }
}
