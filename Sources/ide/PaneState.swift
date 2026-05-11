import SwiftUI

/// 1ペイン分のタブ群を管理するモデル。
/// 上ペイン・下ペインで2インスタンス保持、各々が独立したタブ群を持つ。
@MainActor
final class PaneState: ObservableObject, Identifiable {
    let id = UUID()
    @Published var tabs: [TerminalTab] = []
    @Published var activeIndex: Int = 0

    /// 新規タブ起動時に使う cwd。プロジェクトルートを想定。
    let cwd: URL?

    init(cwd: URL? = nil) {
        self.cwd = cwd
        addTab()
    }

    var activeTab: TerminalTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    func addTab() {
        tabs.append(TerminalTab(title: "shell \(tabs.count + 1)", cwd: cwd))
        activeIndex = tabs.count - 1
    }

    func closeActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        tabs.remove(at: activeIndex)
        if tabs.isEmpty {
            // 最後のタブが閉じたら新規を1つ自動で立てる（PoC 段階の暫定挙動）
            addTab()
        } else {
            activeIndex = min(activeIndex, tabs.count - 1)
        }
        // 未読タブを閉じた可能性があるのでサイドバーのリングを再計算
        ProjectsModel.shared.refreshUnreadProjects()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        // タブを能動的に切替えたら未読通知はクリア
        tabs[index].hasUnreadNotification = false
        ProjectsModel.shared.refreshUnreadProjects()
    }
}
