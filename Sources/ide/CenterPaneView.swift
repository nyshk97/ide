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
        ProjectCenterContent(
            preview: projects.preview(for: project),
            fileTree: projects.fileTree(for: project)
        )
    }
}

/// `FilePreviewModel.currentURL` を観察してツリー / プレビューを切り替える。
/// CenterPaneView 直下に書くと preview を観察できず切替が走らないため
/// 専用の子 view にしている。
///
/// HSplitView は内部 view を if/else で差し替えると user drag した divider 位置を
/// 失うため、両方を ZStack で常駐させて opacity で切替（右ペインの workspace 切替と同じ手法）。
private struct ProjectCenterContent: View {
    @ObservedObject var preview: FilePreviewModel
    @ObservedObject var fileTree: FileTreeModel

    var body: some View {
        ZStack {
            FileTreeView(model: fileTree, preview: preview, onSelectFile: { url in
                fileTree.selectedURL = url
                preview.open(url)
            })
            .opacity(preview.currentURL == nil ? 1 : 0)
            .allowsHitTesting(preview.currentURL == nil)

            if let url = preview.currentURL {
                FilePreviewView(preview: preview, url: url, onClose: { preview.close() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
