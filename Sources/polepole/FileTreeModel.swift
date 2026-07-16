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
    /// reload() を跨いでも保持し、消えたディレクトリだけ落とす。
    @Published var expanded: Set<FilePathKey> = []

    /// `.gitignore` 対象を完全に隠すかどうか。デフォルトは false（薄表示で見せる）。
    @Published var hideIgnored: Bool = false

    /// 最後にプレビューで開いた URL。プレビューを閉じても残し、ツリー行を薄く強調する。
    @Published var selectedURL: URL?

    /// 既に scan 済みのディレクトリ（再展開で重複 scan を防ぐ）。
    private var scannedDirs: Set<FilePathKey> = []

    /// `.gitignore` 判定の注入点（テスト用）。デフォルトは `GitIgnoreChecker.check`。
    /// バックグラウンドから呼ばれるので Sendable。
    var ignoreChecker: @Sendable (URL, [URL]) -> Set<FilePathKey> = { root, paths in
        GitIgnoreChecker.check(in: root, paths: paths)
    }

    /// ignore 判定の後追い反映用の世代番号。reload でツリーが作り直されるたびに進め、
    /// 古い世代の判定結果が新しいツリーに反映されるのを防ぐ。
    private var ignoreGeneration = 0

    /// git status バッジ。3 秒 polling で自動更新。
    let gitStatus: GitStatusModel

    init(project: Project) {
        self.project = project
        self.root = FileNode(url: project.path, isDirectory: true, isSymlink: false)
        self.gitStatus = GitStatusModel(project: project)
        reload()
    }

    /// ルートを scan し直し、リロード前に展開していたディレクトリは引き続き展開する。
    /// 既に存在しないディレクトリは expanded から落とす。
    ///
    /// `.gitignore` 判定（外部プロセス）はここでは待たない: ツリーは即時表示し、
    /// 判定結果はバックグラウンド完了後に後追いで薄表示を付ける（メインスレッドを
    /// git にブロックさせない。2026-07 のフリーズの直接原因だった）。
    func reload() {
        let previouslyExpanded = expanded
        scannedDirs.removeAll()
        ignoreGeneration += 1
        let children = Self.scanChildren(of: project.path)
        root.children = children
        scannedDirs.insert(FilePathKey(project.path))

        var scannedNodes: [FileNode] = children
        var stillExpanded: Set<FilePathKey> = []
        var queue: [FileNode] = children
        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard node.isDirectory, !node.isSymlink else { continue }
            let key = FilePathKey(node.url)
            guard previouslyExpanded.contains(key) else { continue }
            let grandchildren = Self.scanChildren(of: node.url)
            node.children = grandchildren
            scannedDirs.insert(key)
            stillExpanded.insert(key)
            queue.append(contentsOf: grandchildren)
            scannedNodes.append(contentsOf: grandchildren)
        }
        expanded = stillExpanded

        scheduleIgnoreCheck(paths: scannedNodes.map { $0.url })
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

    /// 展開中の全ディレクトリを閉じる（VSCode の Collapse Folders 相当）。
    func collapseAll() {
        expanded.removeAll()
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
        node.children = children
        scannedDirs.insert(key)
        scheduleIgnoreCheck(paths: children.map { $0.url })
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

    /// `.gitignore` 判定をバックグラウンドで実行し、結果をメインスレッドで後追い反映する。
    /// detached には Sendable な値（URL 配列と世代番号）だけを渡す。
    /// FileNode は non-Sendable なので capture せず、反映時にパスから検索し直す。
    private func scheduleIgnoreCheck(paths: [URL]) {
        guard !paths.isEmpty else { return }
        let generation = ignoreGeneration
        let repoRoot = project.path
        let checker = ignoreChecker
        Task.detached(priority: .utility) { [weak self] in
            let ignored = checker(repoRoot, paths)
            guard !ignored.isEmpty else { return }
            await self?.applyIgnoreResult(ignored, paths: paths, generation: generation)
        }
    }

    /// 判定結果を現行ツリーに反映する。reload を跨いだ古い結果（世代不一致）は丸ごと捨てる。
    private func applyIgnoreResult(_ ignored: Set<FilePathKey>, paths: [URL], generation: Int) {
        guard generation == ignoreGeneration else { return }
        var index: [FilePathKey: FileNode] = [:]
        buildIndex(root, into: &index)
        for url in paths {
            let key = FilePathKey(url)
            if ignored.contains(key), let node = index[key] {
                node.isIgnored = true
            }
        }
        objectWillChange.send()
    }

    private func buildIndex(_ node: FileNode, into index: inout [FilePathKey: FileNode]) {
        index[FilePathKey(node.url)] = node
        for child in node.children {
            buildIndex(child, into: &index)
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
