import SwiftUI

@MainActor
final class TerminalTabsModel: ObservableObject {
    /// AppKit からも参照する必要があるので singleton で保持。
    /// (SwiftUI の @StateObject は AppKit から見えないため)
    static let shared = TerminalTabsModel()

    @Published var tabs: [TerminalTab] = []
    @Published var activeIndex: Int = 0

    init() {
        addTab()
    }

    var activeTab: TerminalTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    func addTab() {
        let next = nextDefaultTitle()
        tabs.append(TerminalTab(title: next))
        activeIndex = tabs.count - 1
    }

    func closeActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        tabs.remove(at: activeIndex)
        if tabs.isEmpty {
            // 最後のタブが閉じたら新規を1つ自動で立てる（PoC 段階の暫定挙動）
            addTab()
            return
        }
        activeIndex = min(activeIndex, tabs.count - 1)
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
    }

    private func nextDefaultTitle() -> String {
        "shell \(tabs.count + 1)"
    }
}
