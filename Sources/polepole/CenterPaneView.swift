import SwiftUI

/// 中央のファイルツリーペイン（4 カラムの 2 列目）。
/// 上部に diff バッジボタンの薄いバー、その下にファイルツリーを置く。
/// プレビューは独立した `FilePreviewPaneView` に分離済み（同じ画面で切り替わらない）。
struct FileTreePaneView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    /// `POLEPOLE_TEST_AUTO_EMPTY_HUB=1` で「プロジェクトが何件かあっても」EmptyHubView を出す。
    /// VERIFY 用デバッグフラグ。実データ破壊を避けたスクリーンショット検証で使う。
    private var forceEmptyHub: Bool {
        let v = ProcessInfo.processInfo.environment["POLEPOLE_TEST_AUTO_EMPTY_HUB"] ?? ""
        return v == "1" || v.lowercased() == "true"
    }

    var body: some View {
        VStack(spacing: 0) {
            if projects.activeProject != nil && !forceEmptyHub {
                centerTopBar
                Divider()
            }

            Group {
                if projects.allOrdered.isEmpty || forceEmptyHub {
                    EmptyHubView()
                } else if let active = projects.activeProject {
                    FileTreeWrapper(
                        fileTree: projects.fileTree(for: active),
                        preview: projects.preview(for: active)
                    )
                } else {
                    Text("Select a project from the left")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

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

}

/// FileTreeView を active project に応じて差し替えるラッパ。
/// FileTreeView は project ごとに 1 インスタンスなので、active 切替時に reset される。
private struct FileTreeWrapper: View {
    @ObservedObject var fileTree: FileTreeModel
    @ObservedObject var preview: FilePreviewModel

    var body: some View {
        FileTreeView(model: fileTree, preview: preview, onSelectFile: { url in
            // selectedURL は ProjectsModel.rewireActivePreviewSubscription の sink で
            // preview.currentURL の変化に追従して自動同期されるので、ここでは触らない。
            preview.open(url)
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 中央上部バーの diff バッジボタン。常時表示で、差分の有無で件数 Capsule の色を変える。
///
/// - 差分なし（`gitStatus.statuses.count == 0`): アイコン薄め + "0" の Capsule（グレー背景 + secondary 文字）
/// - 差分あり（`> 0`): アイコン通常色 + 件数 Capsule（accent 背景 + 白文字）
struct DiffBadgeButton: View {
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
        .help(count > 0 ? "Open Diff (\(count) files · Cmd+D)" : "No changes (Cmd+D to check)")
    }
}
