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

        // Cmd+D: diff オーバーレイをトグル。
        // Ghostty のデフォルト cmd+d=new_split:right と競合するが、ide は libghostty の split を
        // 使っていないので localMonitor で先取りして問題ない。
        if mods == .command, event.keyCode == 2 {  // 2 = D
            model.toggleDiffOverlay()
            return true
        }

        // diff overlay 表示中の Cmd+R: 再ロード（既存の Cmd+R fileTreeFocused より優先）。
        if model.diffOverlayVisible, mods == .command, event.keyCode == 15 {  // 15 = R
            model.diffViewModel.reload()
            return true
        }

        // diff overlay 表示中の Esc: 閉じる。
        if model.diffOverlayVisible, event.keyCode == 53 {  // 53 = Esc
            model.closeDiffOverlay()
            return true
        }

        // Cmd+J: 中央ペインを ツリー ↔ プレビュー でトグル。
        if mods == .command, event.keyCode == 38 {  // 38 = J
            model.togglePreview()
            return true
        }

        // Cmd+F: プレビュー表示中ならファイル内検索バーを開く（既に開いていれば再フォーカス）。
        // Cmd+Shift+F（全文検索）は上で先に処理済みなので、ここに来るのは Shift なしの Cmd+F のみ。
        if mods == .command, event.keyCode == 3 {  // 3 = F
            if let preview = model.activePreview, preview.currentURL != nil {
                preview.showFindBar()
                return true
            }
            return false
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
            // Ctrl+N / Ctrl+P: ↓↑ と同じく選択を移動（Emacs バインド）。
            // 修飾キー付きなので IME 変換中でも横取りして OK。
            if mods == .control, event.keyCode == 45 {  // 45 = N
                model.quickSearchMoveSelection(1)
                return true
            }
            if mods == .control, event.keyCode == 35 {  // 35 = P
                model.quickSearchMoveSelection(-1)
                return true
            }
            // IME 変換中（marked text あり）は Esc/矢印/Enter を IME に渡して候補移動・キャンセル・確定させる。
            // Enter をここで握る理由: SwiftUI TextField の .onSubmit は IME 確定の Enter でも発火する
            // 場合があり、その瞬間にファイルが開いてしまう。composing 中は素通りさせて IME に確定させ、
            // 確定後の通常 Enter のみ「選択を開く」に倒す。
            if !isComposingInTextField() {
                switch event.keyCode {
                case 36, 76:  // Return / Enter
                    model.quickSearchConfirm()
                    return true
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
            // Ctrl+N / Ctrl+P: ↓↑ と同じく選択を移動（Emacs バインド）。
            if mods == .control, event.keyCode == 45 {  // 45 = N
                model.fullSearchMoveSelection(1)
                return true
            }
            if mods == .control, event.keyCode == 35 {  // 35 = P
                model.fullSearchMoveSelection(-1)
                return true
            }
            // IME 変換中（marked text あり）は Esc/矢印を IME に渡して候補移動・キャンセルさせる。
            if !isComposingInTextField() {
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
        }

        // プレビュー内検索バー表示中のキー操作（モーダルなオーバーレイが出ていないときだけ）。
        if model.mruOverlay == nil, !model.quickSearchVisible, !model.fullSearchVisible,
           let preview = model.activePreview, preview.findBarVisible {
            // IME で日本語を変換中（marked text あり）のときは Return/Esc を横取りしない。
            // 横取りすると変換確定（Return）や変換キャンセル（Esc）が効かなくなる。
            let composing = isComposingInTextField()
            switch event.keyCode {
            case 53:  // Esc: 検索バーを閉じる（プレビュー自体は閉じない）
                if !composing {
                    preview.hideFindBar()
                    return true
                }
            case 36, 76:  // Return / Enter: 次のマッチ（Shift で前へ）
                if !composing {
                    preview.findNext(forward: !mods.contains(.shift))
                    return true
                }
            default:
                break
            }
            // Cmd+G / Cmd+Shift+G: 次 / 前のマッチ
            if mods == .command, event.keyCode == 5 {  // 5 = G
                preview.findNext(forward: true)
                return true
            }
            if mods == [.command, .shift], event.keyCode == 5 {
                preview.findNext(forward: false)
                return true
            }
        }

        return false
    }

    /// キーウィンドウの first responder（SwiftUI TextField なら field editor の NSTextView）が
    /// IME 変換中＝marked text を持っているか。日本語などの変換中に Return/Esc/矢印を
    /// このモニターで横取りすると、変換確定・キャンセル・候補移動が IME に届かなくなる。
    @MainActor
    private static func isComposingInTextField() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextInputClient else { return false }
        return responder.hasMarkedText()
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
