import SwiftUI

/// 中央ペイン（ファイルツリー / プレビューを切り替える領域）。
/// Phase 2 step6 以降で本実装。現状はプレースホルダ。
struct CenterPaneView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Tree / Preview")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
