import SwiftUI

struct TabsView: View {
    @ObservedObject var pane: PaneState
    @ObservedObject private var workspace: WorkspaceModel = .shared

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                    GhosttyTerminalView(pane: pane)
                        .opacity(index == pane.activeIndex ? 1 : 0)
                        .allowsHitTesting(index == pane.activeIndex)
                        .id(tab.id)
                }
            }
        }
        // active pane 切替は GhosttyTerminalNSView.becomeFirstResponder() 経由で実行する。
        // ここで .onTapGesture を仕込むと NSView への mouseDown を SwiftUI が吸ってしまう。
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
        return Button(action: {
            pane.selectTab(at: index)
            workspace.setActive(pane)
        }) {
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 22)
                .background(active ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var paneIsActive: Bool { workspace.isActive(pane) }
}
