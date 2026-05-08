import SwiftUI

struct TabsView: View {
    @EnvironmentObject var model: TerminalTabsModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                    GhosttyTerminalView()
                        .opacity(index == model.activeIndex ? 1 : 0)
                        .allowsHitTesting(index == model.activeIndex)
                        .id(tab.id)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                tabButton(index: index, tab: tab)
            }
            Button(action: { model.addTab() }) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("New tab (⌘T)")

            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tabButton(index: Int, tab: TerminalTab) -> some View {
        let active = index == model.activeIndex
        return Button(action: { model.selectTab(at: index) }) {
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
}
