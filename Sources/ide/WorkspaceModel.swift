import SwiftUI

/// 1 プロジェクト分の上下 2 ペインを束ねるモデル。
/// プロジェクトごとに 1 インスタンス。`ProjectsModel` が dictionary で保持する。
@MainActor
final class WorkspaceModel: ObservableObject {
    let project: Project?

    let topPane: PaneState
    let bottomPane: PaneState

    @Published var activePane: PaneState

    init(project: Project?) {
        self.project = project
        let cwd = project?.path
        let top = PaneState(cwd: cwd)
        let bottom = PaneState(cwd: cwd)
        self.topPane = top
        self.bottomPane = bottom
        // 初期フォーカスは下ペイン（「下大ターミナル」がメイン作業領域の想定）
        self.activePane = bottom
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
