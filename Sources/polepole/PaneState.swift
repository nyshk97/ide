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
        closeTab(at: activeIndex)
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            // 最後のタブが閉じたら新規を1つ自動で立てる（PoC 段階の暫定挙動）
            addTab()
        } else if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
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
        // TabsView は ZStack で全タブの NSView を残し opacity/hitTesting で隠す構造なので、
        // activeIndex を変えただけだと旧タブの NSView が first responder のまま残り、
        // 見た目は切り替わったのにキー入力が旧タブに入る。新タブの NSView に明示的にフォーカスを移す。
        // タブクリック経路では mouseDown が既にフォーカスを取っているので二重呼びになるが冪等。
        if let view = tabs[index].nsView, let window = view.window {
            window.makeFirstResponder(view)
        }
    }

    /// D&D 並び替え用。source タブを target タブの直前に移動する。
    /// `beforeTabID == nil` は末尾に移動。同一ペイン内のみ（呼び出し側で paneID チェック）。
    /// activeIndex は「並び替え前後で同じ active tab」を指すように追従する（並び替えで
    /// アクティブ表示が無関係なタブに飛んだりしない）。
    func moveTab(from sourceTabID: UUID, before beforeTabID: UUID?) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == sourceTabID }) else { return }
        // 同じ場所への drop と「自分の直前」への drop は no-op
        if let beforeTabID, beforeTabID == sourceTabID { return }
        let activeTabID = activeTab?.id
        let source = tabs.remove(at: sourceIndex)
        let insertIndex: Int
        if let beforeTabID, let idx = tabs.firstIndex(where: { $0.id == beforeTabID }) {
            insertIndex = idx
        } else {
            insertIndex = tabs.count
        }
        tabs.insert(source, at: insertIndex)
        if let activeTabID, let newIdx = tabs.firstIndex(where: { $0.id == activeTabID }) {
            activeIndex = newIdx
        }
    }

    /// Cmd+Opt+→ 用。最後のタブから次を選ぶと先頭に wrap する。
    /// タブが 1 つ以下なら no-op。
    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex + 1) % tabs.count)
    }

    /// Cmd+Opt+← 用。先頭のタブから前を選ぶと最後に wrap する。
    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex - 1 + tabs.count) % tabs.count)
    }
}
