import SwiftUI

/// プロジェクト一覧サイドバー（Phase 2 step2 以降で本実装）。
/// 現状は 3 カラムレイアウトの枠を作るためのプレースホルダ。
struct LeftSidebarView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Projects")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
