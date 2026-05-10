import SwiftUI

struct TabsView: View {
    @ObservedObject var pane: PaneState
    @ObservedObject var workspace: WorkspaceModel

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
        let active = index == pane.activeIndex
        let focused = active && paneIsActive
        return TabObserver(tab: tab) { tab in
            Button(action: {
                self.pane.selectTab(at: index)
                self.workspace.setActive(self.pane)
            }) {
                HStack(spacing: 5) {
                    if let icon = programIcon(tab.foregroundProgram) {
                        icon
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    Text(tab.title)
                        .lineLimit(1)
                        .font(.system(size: 12))
                    if tab.hasUnreadNotification {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(active ? Color.accentColor.opacity(focused ? 0.30 : 0.12) : Color.clear)
                .overlay(alignment: .leading) {
                    if focused {
                        Color.accentColor
                            .frame(width: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
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
