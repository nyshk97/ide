import SwiftUI

/// 1 プロジェクト分の上下 2 ペインを束ねるモデル。
/// プロジェクトごとに 1 インスタンス。`ProjectsModel` が dictionary で保持する。
@MainActor
final class WorkspaceModel: ObservableObject {
    let project: Project?

    let topPane: PaneState
    let bottomPane: PaneState

    @Published var activePane: PaneState

    /// 上下分割 / 下のみ。プロジェクトごとに `Project.paneLayout` として永続化される。
    /// `didSet` で `ProjectsModel.updatePaneLayout` を呼んで自動 persist。
    @Published var paneLayout: PaneLayout {
        didSet {
            guard paneLayout != oldValue else { return }
            if let projectID = project?.id {
                ProjectsModel.shared.updatePaneLayout(projectID: projectID, layout: paneLayout)
            }
        }
    }

    init(project: Project?) {
        self.project = project
        let cwd = project?.path
        let top = PaneState(cwd: cwd)
        let bottom = PaneState(cwd: cwd)
        self.topPane = top
        self.bottomPane = bottom
        // 初期フォーカスは下ペイン（「下大ターミナル」がメイン作業領域の想定）
        self.activePane = bottom
        self.paneLayout = project?.paneLayout ?? .split
    }

    func setActive(_ pane: PaneState) {
        if pane !== activePane {
            activePane = pane
        }
        // active になったペインのカレントタブの未読通知をクリア
        pane.activeTab?.hasUnreadNotification = false
        ProjectsModel.shared.refreshUnreadProjects()
    }

    func isActive(_ pane: PaneState) -> Bool {
        pane === activePane
    }

    /// Cmd+Opt+↑/↓ 用。指定のペインにフォーカスを移す（既にそのペインなら no-op）。
    /// target pane の active tab に対応する NSView を first responder にすると、
    /// becomeFirstResponder の既存フローで setActive とアクティブ化が連動する。
    func focusPane(_ target: PaneState) {
        guard target !== activePane else { return }
        // NSView 参照あり & window 取れ & makeFirstResponder が成功した場合のみ早期 return。
        // 上記いずれかが欠ければ fallback で activePane だけでも動かす（setActive を呼ぶことで
        // タブバーのハイライト等の表示は追従する。キー入力は次のクリック等で正しい view に入る）。
        if let view = target.activeTab?.nsView,
           let window = view.window,
           window.makeFirstResponder(view) {
            return
        }
        setActive(target)
    }

    /// タブを閉じる。最後の 1 個を閉じたときの挙動はペインに応じて分岐する（`handlePaneEmpty` 参照）。
    /// `PaneState.closeTab` の自動 addTab + refreshUnreadProjects 責務をここに集約。
    func closeTab(in pane: PaneState, at index: Int) {
        guard pane.tabs.indices.contains(index) else { return }
        pane.tabs.remove(at: index)
        if pane.tabs.isEmpty {
            handlePaneEmpty(pane)
        } else if index < pane.activeIndex {
            pane.activeIndex -= 1
        } else if pane.activeIndex >= pane.tabs.count {
            pane.activeIndex = pane.tabs.count - 1
        }
        // 未読タブを閉じた可能性があるのでサイドバーのリングを再計算
        ProjectsModel.shared.refreshUnreadProjects()
    }

    /// アクティブペインのアクティブタブを閉じる。`Cmd+W` 経路で使う。
    func closeActiveTabOfActivePane() {
        closeTab(in: activePane, at: activePane.activeIndex)
    }

    /// `.split` ⇔ `.singleBottom` を切替える。`Cmd+Opt+\` と TabsView の分割追加ボタンから呼ぶ。
    /// - `.split → .singleBottom`: activePane を bottomPane に明示遷移
    ///   （畳まれた上ペインに `Cmd+T` / `Cmd+W` が効かないように）
    /// - `.singleBottom → .split`: 上ペインが空ならタブを 1 つ用意
    ///   （「空のまま split」を作らないため）
    func togglePaneLayout() {
        switch paneLayout {
        case .split:
            paneLayout = .singleBottom
            if activePane === topPane {
                activePane = bottomPane
            }
        case .singleBottom:
            if topPane.tabs.isEmpty {
                topPane.addTab()
            }
            paneLayout = .split
        }
    }

    /// ペインのタブが 0 になったときの遷移ルール。
    /// - 上ペインで `.split` 中なら `.singleBottom` に切替えて上ペインを畳む。activePane も bottom に移す
    ///   （畳まれた上ペインに `Cmd+T` / `Cmd+W` が効いてしまうのを防ぐ）。
    /// - それ以外（下ペイン or 1 ペイン中の唯一ペイン）は新規タブを 1 つ自動生成する。
    func handlePaneEmpty(_ pane: PaneState) {
        if pane === topPane && paneLayout == .split {
            paneLayout = .singleBottom
            activePane = bottomPane
        } else {
            pane.addTab()
        }
    }

    /// 上下どちらかのペインのいずれかのタブに未読通知があるか。
    /// サイドバーのプロジェクトリング表示の派生元。
    var hasUnreadTab: Bool {
        topPane.tabs.contains { $0.hasUnreadNotification }
            || bottomPane.tabs.contains { $0.hasUnreadNotification }
    }

    /// 与えられたタブが「真にアクティブ」（active pane の active tab）か。
    /// BEL 通知で「アクティブ時は無視」の判定に使う。
    func isCurrentlyActive(tab: TerminalTab) -> Bool {
        activePane.activeTab === tab
    }
}
