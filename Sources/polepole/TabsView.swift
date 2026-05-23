import SwiftUI

struct TabsView: View {
    @ObservedObject var pane: PaneState
    @ObservedObject var workspace: WorkspaceModel

    @State private var hoveredTabID: TerminalTab.ID?
    @State private var renamingTabID: TerminalTab.ID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFieldFocused: Bool

    /// ForEach のループ内で各 tab を `@ObservedObject` 化するため、ヘルパで個別に観測する
    private struct TabObserver<Content: View>: View {
        @ObservedObject var tab: TerminalTab
        let content: (TerminalTab) -> Content
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
    private func paneContent(index: Int, tab: TerminalTab) -> some View {
        TabObserver(tab: tab) { tab in
            ZStack {
                // .id に generation を混ぜると restart() で view 再生成→新 surface
                GhosttyTerminalView(pane: self.pane, tab: tab)
                    .id("\(tab.id.uuidString)-\(tab.generation)")
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
            }
            Button(action: { pane.addTab(); workspace.setActive(pane) }) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")

            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(paneIsActive ? Color.accentColor.opacity(0.05) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabButton(index: Int, tab: TerminalTab) -> some View {
        TabObserver(tab: tab) { tab in
            TabButton(
                tab: tab,
                index: index,
                isActive: index == pane.activeIndex,
                isFocused: index == pane.activeIndex && paneIsActive,
                isHovered: hoveredTabID == tab.id,
                isRenaming: renamingTabID == tab.id,
                renameDraft: $renameDraft,
                renameFieldFocused: $renameFieldFocused,
                onSelect: {
                    self.pane.selectTab(at: index)
                    self.workspace.setActive(self.pane)
                },
                onClose: { self.pane.closeTab(at: index) },
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
