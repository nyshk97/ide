import SwiftUI
import AppKit

/// アクティブプロジェクトのファイルツリーを描画する。
/// CenterPaneView 内で使う想定。閲覧専用、CRUD なし（要件 7）。
struct FileTreeView: View {
    @ObservedObject var model: FileTreeModel
    @ObservedObject var gitStatus: GitStatusModel
    @ObservedObject var projects: ProjectsModel = .shared

    /// ファイル（=ディレクトリ以外）をクリックしたときの callback（プレビュー切替用）。
    let onSelectFile: (URL) -> Void

    init(model: FileTreeModel, onSelectFile: @escaping (URL) -> Void = { _ in }) {
        self.model = model
        self.gitStatus = model.gitStatus
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
        HStack(spacing: 6) {
            Image(systemName: "tree")
                .foregroundStyle(.secondary)
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
            .help("再スキャン")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    /// 表示するノード列。`hideIgnored` のときは ignored を完全除外。
    private func visibleChildren(of node: FileNode) -> [FileNode] {
        if model.hideIgnored {
            return node.children.filter { !$0.isIgnored }
        }
        return node.children
    }

    private func rowView(node: FileNode, depth: Int, isExpanded: Bool) -> some View {
        HStack(spacing: 4) {
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
        .onTapGesture {
            if node.isDirectory && !node.isSymlink {
                model.toggleExpanded(node.url)
            } else if !node.isDirectory {
                onSelectFile(node.url)
            }
        }
        .contextMenu {
            Button("相対パスをコピー") { copyRelativePath(node) }
            Button("ターミナルで開く") { openInTerminal(node) }
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

    private func openInTerminal(_ node: FileNode) {
        let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        // active workspace の active pane の active tab に `cd` を流す
        guard let workspace = projects.activeWorkspace else { return }
        let pane = workspace.activePane
        guard let tab = pane.activeTab else { return }
        // ghostty surface に直接書き込めるが、cmux 同様シンプルに `cd <path>` + Enter を流す。
        // ここはあえて Ghostty 側に echo させる: surface 経由で文字列を送るには
        // GhosttyTerminalNSView の API が必要。step6 では暫定で「クリックで cd 文字列を
        // クリップボードにコピーするだけ」にし、step8 以降の実装で正式に流す。
        // → ここでは pasteboard に "cd <path>" を入れて手で貼ってもらう運用にする。
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("cd \(dir.path)\n", forType: .string)
        _ = tab  // unused 警告抑制（将来 surface に直接送るためのフック）
    }
}
