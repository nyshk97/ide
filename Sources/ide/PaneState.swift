import SwiftUI

/// 1ペイン分のタブ群を管理するモデル。
/// Phase 1 では上ペイン・下ペインで2インスタンス保持、各々が独立したタブ群を持つ。
@MainActor
final class PaneState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var tabs: [TerminalTab] = []
    @Published var activeIndex: Int = 0

    init() {
        addTab()
    }

    var activeTab: TerminalTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    func addTab() {
        tabs.append(TerminalTab(title: "shell \(tabs.count + 1)"))
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
}
