import SwiftUI

/// 上下 2 ペインを束ねるトップレベルモデル。
/// AppKit 側からも参照する必要があるので singleton。
@MainActor
final class WorkspaceModel: ObservableObject {
    static let shared = WorkspaceModel()

    let topPane: PaneState
    let bottomPane: PaneState

    @Published var activePane: PaneState

    private init() {
        let top = PaneState()
        let bottom = PaneState()
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
    }

    func isActive(_ pane: PaneState) -> Bool {
        pane === activePane
    }

    /// 与えられたタブが「真にアクティブ」（active pane の active tab）か。
    /// BEL 通知で「アクティブ時は無視」の判定に使う。
    func isCurrentlyActive(tab: TerminalTab) -> Bool {
        activePane.activeTab === tab
    }
}
