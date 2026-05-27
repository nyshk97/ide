import SwiftUI

struct TabsView: View {
    @ObservedObject var pane: PaneState
    @ObservedObject var workspace: WorkspaceModel
    /// help テキストにバインド済みショートカット (⌘/ など) を表示するため。
    /// ユーザーが Settings でリバインドしたら自動追従する。
    @ObservedObject private var shortcuts = ShortcutsStore.shared

    @State private var hoveredTabID: TerminalTab.ID?
    @State private var renamingTabID: TerminalTab.ID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool
    /// D&D 並び替え中のドロップ位置インジケータ表示用。
    @State private var dropTarget: DropTarget = .none

    enum DropTarget: Equatable {
        case none
        case beforeTab(UUID)
        case end
    }

    /// drag payload は "paneID|tabID" 形式の文字列。
    /// paneID を載せておくことで dropDestination 側で同一ペイン / 別ペインを判定できる。
    private func dragPayload(for tab: TerminalTab) -> String {
        "\(pane.id.uuidString)|\(tab.id.uuidString)"
    }

    /// payload を分解して (source pane ID, source tab ID) を返す。
    /// 別ペイン間移動 (Phase 3) でも source pane を引きたいので、同一ペイン制限はかけない。
    private func parseDragPayload(_ items: [String]) -> (paneID: UUID, tabID: UUID)? {
        guard let payload = items.first else { return nil }
        let parts = payload.split(separator: "|")
        guard parts.count == 2,
              let sourcePaneID = UUID(uuidString: String(parts[0])),
              let sourceTabID = UUID(uuidString: String(parts[1])) else { return nil }
        return (sourcePaneID, sourceTabID)
    }

    /// source pane ID から workspace 内の対応 PaneState を引く。topPane / bottomPane のどちらか。
    private func paneByID(_ id: UUID) -> PaneState? {
        if workspace.topPane.id == id { return workspace.topPane }
        if workspace.bottomPane.id == id { return workspace.bottomPane }
        return nil
    }

    /// drop された payload を「同一ペイン並び替え」「別ペイン移動」に振り分けて実行する。
    private func handleDrop(items: [String], beforeTabID: UUID?) -> Bool {
        guard let ref = parseDragPayload(items) else { return false }
        if ref.paneID == pane.id {
            pane.moveTab(from: ref.tabID, before: beforeTabID)
        } else if let sourcePane = paneByID(ref.paneID) {
            workspace.moveTab(ref.tabID, from: sourcePane, to: pane, before: beforeTabID)
        } else {
            return false
        }
        return true
    }

    /// ForEach のループ内で各 tab を `@ObservedObject` 化するため、ヘルパで個別に観測する
    private struct TabObserver<Content: View>: View {
        @ObservedObject var tab: TerminalTab
        @ViewBuilder let content: (TerminalTab) -> Content
        var body: some View { content(tab) }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                    paneContent(index: index, tab: tab)
                        .opacity(index == pane.activeIndex ? 1 : 0)
                        .allowsHitTesting(index == pane.activeIndex)
                }
            }
        }
        // active pane 切替は GhosttyTerminalNSView.becomeFirstResponder() 経由で実行する。
        // ここで .onTapGesture を仕込むと NSView への mouseDown を SwiftUI が吸ってしまう。
    }

    /// 1タブ分の表示。lifecycle に応じて exited overlay を被せる。
    /// 実体の Ghostty surface (`tab.realNSView`) は `WorkspaceModel.terminalsHost` に attach されており、
    /// この `TerminalAnchorView` の frame に追従して表示される (Phase 3 portal host 方式)。
    private func paneContent(index: Int, tab: TerminalTab) -> some View {
        TabObserver(tab: tab) { tab in
            ZStack {
                TerminalAnchorView(tab: tab,
                                   pane: self.pane,
                                   workspace: workspace,
                                   isActive: index == pane.activeIndex && paneIsVisible)
                    .id(tab.id)
                if case .exited(let code) = tab.lifecycle {
                    ExitedOverlayView(exitCode: code, onRestart: { tab.restart() })
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                tabButton(index: index, tab: tab)
                    .overlay(alignment: .leading) {
                        // この tab の直前へ drop するときのインジケータ（2px 縦線）
                        if dropTarget == .beforeTab(tab.id) {
                            Color.accentColor.frame(width: 2)
                                .padding(.vertical, 2)
                                .offset(x: -3)
                        }
                    }
            }
            // + ボタンに dropDestination を兼ねさせる（末尾並べ替え）。
            // 専用の透明領域を挟むと + ボタンが右に離れすぎるため、領域を共有する。
            Button(action: { pane.addTab(); workspace.setActive(pane) }) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")
            .overlay(alignment: .leading) {
                if dropTarget == .end {
                    Color.accentColor.frame(width: 2)
                        .padding(.vertical, 2)
                        .offset(x: -3)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                let ok = handleDrop(items: items, beforeTabID: nil)
                dropTarget = .none
                return ok
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTarget = .end
                } else if dropTarget == .end {
                    dropTarget = .none
                }
            }

            // 下ペインのタブバーに、ペインレイアウト切替ボタンを常時表示する。
            // - .split のとき: 上ペインを畳む（→ 1 ペイン化）
            // - .singleBottom のとき: 上ペインを復活させる（→ 2 ペイン化）
            // Cmd+Opt+\ のショートカットと同等。下ペインを「メイン作業領域」と位置付けているので
            // 上ペイントグルのコントロールは下ペイン側に置く。
            if pane === workspace.bottomPane {
                Button(action: { workspace.togglePaneLayout() }) {
                    Image(systemName: workspace.paneLayout == .split
                          ? "rectangle.bottomhalf.filled"
                          : "rectangle.split.1x2")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help((workspace.paneLayout == .split ? "Hide top pane" : "Split pane")
                      + " (\(shortcuts.combo(for: .togglePaneLayout).display))")
            }

            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(paneIsActive ? Color.accentColor.opacity(0.05) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabButton(index: Int, tab: TerminalTab) -> some View {
        TabObserver(tab: tab) { tab in
            let isRenaming = renamingTabID == tab.id
            let core = TabButton(
                tab: tab,
                index: index,
                isActive: index == pane.activeIndex,
                isFocused: index == pane.activeIndex && paneIsActive,
                isHovered: hoveredTabID == tab.id,
                isRenaming: isRenaming,
                renameDraft: $renameDraft,
                renameFieldFocused: $renameFieldFocused,
                onSelect: {
                    self.pane.selectTab(at: index)
                    self.workspace.setActive(self.pane)
                },
                onClose: { self.workspace.closeTab(in: self.pane, at: index) },
                onBeginRename: { beginRename(tab: tab) },
                onCommitRename: { commitRename(tab: tab) },
                onCancelRename: { cancelRename() },
                programIcon: programIcon(tab.foregroundProgram)
            )
            .onHover { hovering in
                if hovering {
                    hoveredTabID = tab.id
                } else if hoveredTabID == tab.id {
                    hoveredTabID = nil
                }
            }

            // rename 中は .draggable を付けない（TextField のテキスト選択ドラッグと競合させない）。
            // dropDestination は付けたまま（他タブから rename 中タブの位置にドロップしたい）。
            Group {
                if isRenaming {
                    core
                } else {
                    core.draggable(dragPayload(for: tab)) {
                        Text(tab.title)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .dropDestination(for: String.self) { items, _ in
                let ok = handleDrop(items: items, beforeTabID: tab.id)
                dropTarget = .none
                return ok
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTarget = .beforeTab(tab.id)
                } else if dropTarget == .beforeTab(tab.id) {
                    dropTarget = .none
                }
            }
        }
    }

    private func beginRename(tab: TerminalTab) {
        renameDraft = tab.title
        renamingTabID = tab.id
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename(tab: TerminalTab) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tab.title = trimmed
        }
        renamingTabID = nil
        renameFieldFocused = false
    }

    private func cancelRename() {
        renamingTabID = nil
        renameFieldFocused = false
    }

    private var paneIsActive: Bool { workspace.isActive(pane) }

    /// このペイン自身が画面に表示されているか。`.singleBottom` モード中の `topPane` は collapsed なので
    /// 非表示扱い。`TerminalAnchorView.isActive` の判定に使い、host が裏ペインの realNSView を
    /// オフスクリーン化できるようにする (collapsed transition で古い frame が通知されても画面に出ない)。
    private var paneIsVisible: Bool {
        workspace.paneLayout == .split || pane === workspace.bottomPane
    }

    private func programIcon(_ program: TerminalTab.ForegroundProgram) -> Text? {
        switch program {
        case .claude:
            return Text("🅒").foregroundStyle(Color.orange)
        case .codex:
            return Text("🅞").foregroundStyle(Color.green)
        case .other, .shell:
            // shell とその他は無印
            return nil
        }
    }
}

/// タブ 1 件分の見た目。型推論を軽くするため TabsView の外に切り出している。
private struct TabButton: View {
    @ObservedObject var tab: TerminalTab
    let index: Int
    let isActive: Bool
    let isFocused: Bool
    let isHovered: Bool
    let isRenaming: Bool
    @Binding var renameDraft: String
    var renameFieldFocused: FocusState<Bool>.Binding
    let onSelect: () -> Void
    let onClose: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let programIcon: Text?

    var body: some View {
        HStack(spacing: 5) {
            if let icon = programIcon {
                icon
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            titleView
            if tab.hasUnreadNotification {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 6, height: 6)
            }
            closeButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 22)
        .background(background)
        .overlay(alignment: .leading) {
            if isFocused {
                Color.accentColor.frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onBeginRename() }
        .onTapGesture { if !isRenaming { onSelect() } }
        .contextMenu {
            Button("Rename…") { onBeginRename() }
            Button("Close Tab") { onClose() }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if isRenaming {
            TextField("", text: $renameDraft, onCommit: onCommitRename)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(renameFieldFocused)
                .frame(minWidth: 40, maxWidth: 160)
                .fixedSize(horizontal: true, vertical: false)
                .onExitCommand { onCancelRename() }
        } else {
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12))
        }
    }

    private var background: Color {
        if isActive {
            return Color.accentColor.opacity(isFocused ? 0.30 : 0.12)
        }
        return .clear
    }

    /// ホバー時に表示する × ボタン。非表示時も frame を確保してタブ幅のジャンプを避ける。
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .opacity(isHovered && !isRenaming ? 1 : 0)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isHovered && !isRenaming)
        .help("Close tab (⌘W)")
    }
}
