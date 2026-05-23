import SwiftUI

/// プロジェクト 1 つ分のファイルツリーを保持するモデル。
/// プロジェクトごとに `ProjectsModel.fileTree(for:)` で遅延作成。
///
/// 初期スキャンはルート直下のみ。ディレクトリは展開された瞬間に lazy scan する
/// （`.git` のような巨大な隠しディレクトリで初期化が固まらないようにするため）。
@MainActor
final class FileTreeModel: ObservableObject {
    let project: Project

    /// ルートノード。`reload()` で再構築。
    @Published private(set) var root: FileNode

    /// 展開状態（プロジェクト内のパス集合）。再起動でリセット（要件通り）。
    @Published var expanded: Set<FilePathKey> = []

    /// `.gitignore` 対象を完全に隠すかどうか。デフォルトは false（薄表示で見せる）。
    @Published var hideIgnored: Bool = false

    /// 最後にプレビューで開いた URL。プレビューを閉じても残し、ツリー行を薄く強調する。
    @Published var selectedURL: URL?

    /// 既に scan 済みのディレクトリ（再展開で重複 scan を防ぐ）。
    private var scannedDirs: Set<FilePathKey> = []

    /// git status バッジ。3 秒 polling で自動更新。
    let gitStatus: GitStatusModel

    init(project: Project) {
        self.project = project
        self.root = FileNode(url: project.path, isDirectory: true, isSymlink: false)
        self.gitStatus = GitStatusModel(project: project)
        reload()
    }

    /// ルート + 直下子のみを scan する。展開状態はリセット。
    func reload() {
        scannedDirs.removeAll()
        let children = Self.scanChildren(of: project.path)
        applyIgnored(in: children, parentDir: project.path)
        root.children = children
        scannedDirs.insert(FilePathKey(project.path))
        gitStatus.scheduleRefresh()
        objectWillChange.send()
    }

    func toggleExpanded(_ url: URL) {
        let key = FilePathKey(url)
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
            scanIfNeeded(url)
        }
    }

    func isExpanded(_ url: URL) -> Bool {
        expanded.contains(FilePathKey(url))
    }

    /// 指定 URL が「最後にプレビューで開いた」ものかどうか（ツリー行の薄い強調表示用）。
    func isSelected(_ url: URL) -> Bool {
        guard let selectedURL else { return false }
        return FilePathKey(selectedURL) == FilePathKey(url)
    }

    /// 展開するディレクトリの children を遅延 scan する。
    private func scanIfNeeded(_ url: URL) {
        let key = FilePathKey(url)
        guard !scannedDirs.contains(key) else { return }
        guard let node = findNode(url: url) else { return }
        let children = Self.scanChildren(of: url)
        applyIgnored(in: children, parentDir: url)
        node.children = children
        scannedDirs.insert(key)
        objectWillChange.send()
    }

    private func findNode(url: URL) -> FileNode? {
        return findNode(in: root, target: FilePathKey(url))
    }

    private func findNode(in node: FileNode, target: FilePathKey) -> FileNode? {
        if FilePathKey(node.url) == target { return node }
        for child in node.children {
            if let found = findNode(in: child, target: target) { return found }
        }
        return nil
    }

    /// 指定ディレクトリの直下にあるノードに対して `.gitignore` 判定をまとめて適用。
    private func applyIgnored(in nodes: [FileNode], parentDir: URL) {
        let ignored = GitIgnoreChecker.check(in: project.path, paths: nodes.map { $0.url })
        for node in nodes where ignored.contains(FilePathKey(node.url)) {
            node.isIgnored = true
        }
    }

    /// ディレクトリの直下のみを scan。サブディレクトリは展開時に再帰しない。
    /// ディレクトリ symlink は辿らず単独ノードとして表示。
    private static func scanChildren(of directory: URL) -> [FileNode] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey]

        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [/* 隠しファイル含む（要件: 隠しファイル表示） */]
        ) else { return [] }

        var children: [FileNode] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let isSymlink = values?.isSymbolicLink ?? false
            let isDir = values?.isDirectory ?? false
            if isSymlink {
                let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)).flatMap {
                    URL(fileURLWithPath: $0)
                }
                children.append(FileNode(
                    url: url,
                    isDirectory: isDir,
                    isSymlink: true,
                    symlinkTarget: target
                ))
            } else {
                children.append(FileNode(url: url, isDirectory: isDir, isSymlink: false))
            }
        }

        // フォルダ先・アルファベット昇順（要件通り）。
        children.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return children
    }
}
