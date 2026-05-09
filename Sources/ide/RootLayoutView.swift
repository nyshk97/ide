import SwiftUI

/// IDE 全体のルートレイアウト（3 カラム）。
/// 左: プロジェクト一覧サイドバー / 中央: ファイルツリー or プレビュー / 右: ターミナル。
/// ペイン比率は `HSplitView` のドラッグハンドルで変更でき、保存はしない（要件通り）。
struct RootLayoutView: View {
    var body: some View {
        // SwiftUI の HSplitView は idealWidth を尊重せず初期は均等分割になりがちなので、
        // maxWidth で起動時の幅レンジを絞り、右ペイン（ターミナル）だけ無限に伸びるようにする。
        HSplitView {
            LeftSidebarView()
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 240)
            CenterPaneView()
                .frame(minWidth: 200, idealWidth: 320, maxWidth: 480)
            WorkspaceView()
                .frame(minWidth: 400)
        }
    }
}
