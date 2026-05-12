import SwiftUI
import AppKit

/// アクティブプロジェクトのファイルツリーを描画する。
/// CenterPaneView 内で使う想定。閲覧専用、CRUD なし（要件 7）。
struct FileTreeView: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var gitStatus: GitStatusModel
    @ObservedObject var preview: FilePreviewModel

    /// ファイル（=ディレクトリ以外）をクリックしたときの callback（プレビュー切替用）。
    let onSelectFile: (URL) -> Void

    /// マウスオーバー中のノード。背景色強調に使う。
    @State private var hoveredNodeID: FileNode.ID?

    /// ツリーがキーボードフォーカスを持っているか。`ProjectsModel.fileTreeFocused` に同期し、
    /// Cmd+R での再スキャン可否判定に使う（フォーカスが端末側にあるときは誤発火させない）。
    @FocusState private var treeFocused: Bool

    init(model: FileTreeModel, preview: FilePreviewModel, onSelectFile: @escaping (URL) -> Void = { _ in }) {
        self.model = model
        self.gitStatus = model.gitStatus
        self.preview = preview
        self.onSelectFile = onSelectFile
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(flattenedNodes(), id: \.node.id) { entry in
                        rowView(node: entry.node, depth: entry.depth, isExpanded: model.isExpanded(entry.node.url))
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($treeFocused)
        }
        .onChange(of: treeFocused) { _, focused in
            ProjectsModel.shared.fileTreeFocused = focused
        }
        .onChange(of: preview.currentURL) { _, url in
            // プレビュー表示に切り替わったらツリーはフォーカスを失う扱いにする。
            if url != nil {
                treeFocused = false
                ProjectsModel.shared.fileTreeFocused = false
            }
        }
    }

    /// 表示するノードを (node, depth) のフラットな配列として返す。
    /// 再帰的な ViewBuilder を避けるため、データ側で flatten する。
    private struct DisplayEntry {
        let node: FileNode
        let depth: Int
    }

    private func flattenedNodes() -> [DisplayEntry] {
        var result: [DisplayEntry] = []
        appendVisible(of: model.root, depth: 0, into: &result)
        return result
    }

    private func appendVisible(of node: FileNode, depth: Int, into result: inout [DisplayEntry]) {
        for child in visibleChildren(of: node) {
            result.append(DisplayEntry(node: child, depth: depth))
            if child.isDirectory && !child.isSymlink && model.isExpanded(child.url) {
                appendVisible(of: child, depth: depth + 1, into: &result)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            // ツリー ↔ プレビュー トグル。プレビュー側の folder アイコンと同じ位置に置く。
            // 履歴がない（一度もファイルを開いていない）ときは disabled。
            Button {
                preview.toggle()
            } label: {
                Image(systemName: "doc.text")
                    .foregroundStyle(preview.canRestorePreview ? Color.secondary : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .disabled(!preview.canRestorePreview)
            .help("Cmd+J で最後に見たファイルを表示")

            Text(model.project.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Button {
                model.hideIgnored.toggle()
            } label: {
                Image(systemName: model.hideIgnored ? "eye.slash" : "eye")
                    .foregroundStyle(model.hideIgnored ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(model.hideIgnored ? ".gitignore 対象を表示" : ".gitignore 対象を非表示")
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("再スキャン（ツリーにフォーカス時 Cmd+R）")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    /// 表示するノード列。`hideIgnored` のときは ignored を完全除外。
    private func visibleChildren(of node: FileNode) -> [FileNode] {
        if model.hideIgnored {
            return node.children.filter { !$0.isIgnored }
        }
        return node.children
    }

    private func rowView(node: FileNode, depth: Int, isExpanded: Bool) -> some View {
        let isHovered = hoveredNodeID == node.id
        let isSelected = model.isSelected(node.url)
        return HStack(spacing: 4) {
            // インデント
            Spacer().frame(width: CGFloat(depth) * 14)

            // 展開トグル（ディレクトリのみ）
            if node.isDirectory && !node.isSymlink {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
            } else {
                Spacer().frame(width: 12)
            }

            // アイコン
            Image(systemName: iconName(for: node))
                .foregroundStyle(iconColor(for: node))
                .frame(width: 14)

            // 名前
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            // symlink 矢印
            if node.isSymlink {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                if let target = node.symlinkTarget {
                    Text(target.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            if let badge = gitStatus.badge(for: node.url) {
                Text(badge.letter)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(badge.color)
                    .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(node.isIgnored ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .background(rowBackground(isHovered: isHovered, isSelected: isSelected))
        .onHover { hovering in
            if hovering {
                hoveredNodeID = node.id
            } else if hoveredNodeID == node.id {
                hoveredNodeID = nil
            }
        }
        .onTapGesture {
            // 行をクリックしたらツリーにフォーカスを持たせる（@FocusState の自動遷移に頼らない）。
            treeFocused = true
            ProjectsModel.shared.fileTreeFocused = true
            if node.isDirectory && !node.isSymlink {
                model.toggleExpanded(node.url)
            } else if !node.isDirectory {
                onSelectFile(node.url)
            }
        }
        .contextMenu {
            Button("相対パスをコピー") { copyRelativePath(node) }
            Button("Finder で開く") { openInFinder(node) }
        }
    }

    /// ホバー / 選択中の背景色。VS Code の Explorer 風に薄グレーで全幅塗る。
    /// 選択中は少し濃く、ホバーと重なる場合はさらに濃くする。
    @ViewBuilder
    private func rowBackground(isHovered: Bool, isSelected: Bool) -> some View {
        if isSelected && isHovered {
            Color.primary.opacity(0.14)
        } else if isSelected {
            Color.primary.opacity(0.10)
        } else if isHovered {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }

    // MARK: - アイコン

    private func iconName(for node: FileNode) -> String {
        if node.isDirectory {
            return node.isSymlink ? "folder.badge.questionmark" : "folder"
        }
        // 拡張子別の SF Symbols。網羅は最低限、後段で増やす余地あり。
        switch node.ext {
        case "swift": return "swift"
        case "md", "markdown": return "doc.richtext"
        case "json", "yaml", "yml", "toml": return "doc.text"
        case "sh", "zsh", "bash": return "terminal"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return "photo"
        case "pdf": return "doc.fill"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "tsx", "jsx": return "curlybraces"
        case "html", "htm": return "globe"
        case "css", "scss": return "paintbrush"
        case "lock": return "lock.doc"
        default: return "doc"
        }
    }

    private func iconColor(for node: FileNode) -> Color {
        if node.isDirectory {
            return .blue
        }
        switch node.ext {
        case "swift": return .orange
        case "md", "markdown": return .purple
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return .pink
        default: return .secondary
        }
    }

    // MARK: - 右クリックメニュー

    private func copyRelativePath(_ node: FileNode) {
        let rootPath = model.project.path.standardizedFileURL.path
        let absolute = node.url.standardizedFileURL.path
        let relative: String
        if absolute == rootPath {
            relative = "."
        } else if absolute.hasPrefix(rootPath + "/") {
            relative = String(absolute.dropFirst(rootPath.count + 1))
        } else {
            relative = absolute
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(relative, forType: .string)
    }

    private func openInFinder(_ node: FileNode) {
        if node.isDirectory {
            // ディレクトリ自体を Finder ウィンドウとして開く。
            NSWorkspace.shared.open(node.url)
        } else {
            // 親フォルダを開いて当該ファイルを選択状態にする。
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }
}
