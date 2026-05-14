import SwiftUI

/// 中央ペイン（ファイルツリー / プレビューを切り替える領域）。
/// 上部に共通ツールバー（diff バッジボタン）を持ち、その下にツリー or プレビューを置く。
struct CenterPaneView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    var body: some View {
        VStack(spacing: 0) {
            if projects.activeProject != nil {
                centerTopBar
                Divider()
            }

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
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 中央ペインの共通上部バー。プレビュー時もツリー時も常に出す。
    /// 既存の `FilePreviewView.toolbar`（[←][→][🌲]）はプレビュー時にしか出ないので、
    /// それと別の薄いバーをここで持つ（プレビュー時は 2 段になる）。
    @ViewBuilder
    private var centerTopBar: some View {
        if let active = projects.activeProject {
            HStack(spacing: 8) {
                Spacer()
                DiffBadgeButton(
                    gitStatus: projects.fileTree(for: active).gitStatus,
                    onClick: { projects.toggleDiffOverlay() }
                )
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
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
                FilePreviewView(preview: preview, url: url, projectRoot: fileTree.project.path, onClose: { preview.close() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 中央上部バーの diff バッジボタン。常時表示で、差分の有無で件数 Capsule の色を変える。
///
/// - 差分なし（`gitStatus.statuses.count == 0`): アイコン薄め + "0" の Capsule（グレー背景 + secondary 文字）
/// - 差分あり（`> 0`): アイコン通常色 + 件数 Capsule（accent 背景 + 白文字）
private struct DiffBadgeButton: View {
    @ObservedObject var gitStatus: GitStatusModel
    let onClick: () -> Void

    @State private var hovered: Bool = false

    var body: some View {
        let count = gitStatus.statuses.count
        Button(action: onClick) {
            HStack(spacing: 4) {
                Image("git-branch")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 14, height: 14)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(count > 0 ? Color.white : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(count > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                    )
            }
            .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(count > 0 ? "Diff を開く (\(count) 件・Cmd+D)" : "差分なし (Cmd+D で確認)")
    }
}

