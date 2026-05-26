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
