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
        guard pane !== activePane else { return }
        activePane = pane
    }

    func isActive(_ pane: PaneState) -> Bool {
        pane === activePane
    }
}
