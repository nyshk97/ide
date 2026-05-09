import SwiftUI

/// 上小ターミナル + 下大ターミナルの 2 ペイン構成。
/// `VSplitView` がドラッグハンドルを提供する（macOS 13+）。
struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        VSplitView {
            TabsView(pane: workspace.topPane, workspace: workspace)
                .frame(minHeight: 80, idealHeight: 180)
            TabsView(pane: workspace.bottomPane, workspace: workspace)
                .frame(minHeight: 200)
        }
    }
}
