import SwiftUI

/// 中央ペイン（ファイルツリー / プレビューを切り替える領域）。
/// step6 以降で本実装。step2 では空状態の案内と暫定プレースホルダだけ持つ。
struct CenterPaneView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    var body: some View {
        Group {
            if projects.allOrdered.isEmpty {
                emptyState
            } else if let active = projects.activeProject {
                placeholder(for: active)
            } else {
                Text("左からプロジェクトを選択")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("フォルダを追加して始めよう")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("左サイドバー上部の「+」からフォルダを選択してください。")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func placeholder(for project: Project) -> some View {
        let preview = projects.preview(for: project)
        if let url = preview.currentURL {
            FilePreviewView(url: url, onClose: { preview.close() })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileTreeView(model: projects.fileTree(for: project), onSelectFile: { url in
                preview.open(url)
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
