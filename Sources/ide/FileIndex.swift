import Foundation
import SwiftUI

/// プロジェクト 1 つ分のファイル + ディレクトリインデックス。
///
/// 初期構築は project 起動時に再帰スキャン（バックグラウンド queue で実行）。
/// 大規模リポジトリでも 1〜数秒で済む程度の軽い処理として実装。
@MainActor
final class FileIndex: ObservableObject {
    let project: Project

    /// インデックス済みのエントリ（ファイルとディレクトリ両方）。
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isBuilding: Bool = false

    /// `.gitignore` 対象を検索結果に含めるか。トグル切替で再スキャン。
    /// 起動時はプロジェクトを問わず false（要件 6.1: デフォルトで除外）。
    @Published var includeIgnored: Bool = false {
        didSet {
            if oldValue != includeIgnored { rebuild() }
        }
    }

    /// 直近開いたファイルのパス → 開いた時刻。スコアリング上位に効かせる。
    var recents: [FilePathKey: Date] = [:]

    struct Entry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        /// project root からの相対パス（小文字化済みは検索用に別保持）
        let relativePath: String
        let lowercaseRelativePath: String
        let lowercaseName: String
        var id: URL { url }
    }

    init(project: Project) {
        self.project = project
        rebuild()
    }

    func rebuild() {
        isBuilding = true
        let root = project.path
        let includeIgnored = self.includeIgnored
        Task.detached { [weak self] in
            let entries = Self.scan(root: root, includeIgnored: includeIgnored)
            await MainActor.run {
                self?.entries = entries
                self?.isBuilding = false
            }
        }
    }

    /// クエリに対する上位 N 件をスコア降順で返す。
    /// スラッシュを含むクエリはパスマッチに自動切替（lowercaseRelativePath で部分一致）。
    func search(_ query: String, limit: Int = 60) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            // 空クエリ: 直近開いたものを上位に並べる
            return entries.sorted { lhs, rhs in
                let l = recents[FilePathKey(lhs.url)] ?? .distantPast
                let r = recents[FilePathKey(rhs.url)] ?? .distantPast
                return l > r
            }.prefix(limit).map { $0 }
        }

        if q.contains("/") {
            // パスマッチ: 部分一致 + 連続文字優先
            return entries
                .compactMap { e -> (Entry, Int)? in
                    guard e.lowercaseRelativePath.contains(q) else { return nil }
                    var score = 1000
                    if e.lowercaseRelativePath.hasPrefix(q) { score += 500 }
                    if let r = recents[FilePathKey(e.url)] {
                        score += Int(r.timeIntervalSince1970 / 1000)
                    }
                    return (e, score)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { $0.0 }
        }

        // ファジーマッチ: name に対して優先度高め、次にパス全体
        return entries
            .compactMap { e -> (Entry, Int)? in
                let nameScore = fuzzyScore(query: q, target: e.lowercaseName)
                let pathScore = fuzzyScore(query: q, target: e.lowercaseRelativePath) / 2
                let total = max(nameScore, pathScore)
                guard total > 0 else { return nil }
                var score = total
                if let r = recents[FilePathKey(e.url)] {
                    score += Int(r.timeIntervalSince1970 / 1000)
                }
                return (e, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// プレビューを開くたびに呼ぶ。直近スコアに効く。
    func recordOpen(_ url: URL) {
        recents[FilePathKey(url)] = .now
    }

    // MARK: - 内部

    /// 簡易ファジーマッチスコア。
    /// - 各クエリ文字が target 内に「順番通り」現れるかチェックし、隣接ボーナス・先頭ボーナスで加点。
    /// - 1 文字も match しなければ 0 を返す。
    nonisolated private func fuzzyScore(query: String, target: String) -> Int {
        guard !query.isEmpty, !target.isEmpty else { return 0 }
        let qChars = Array(query)
        let tChars = Array(target)
        var qi = 0
        var score = 0
        var lastMatchIdx = -1
        var consecutive = 0
        for (ti, tc) in tChars.enumerated() {
            if qi < qChars.count && tc == qChars[qi] {
                score += 10
                if lastMatchIdx + 1 == ti { consecutive += 1; score += consecutive * 5 } else { consecutive = 0 }
                if ti == 0 { score += 8 }
                lastMatchIdx = ti
                qi += 1
            }
        }
        guard qi == qChars.count else { return 0 }  // 全クエリ文字が含まれることが必要
        return score
    }

    /// project root から再帰スキャン。シンボリックリンクは辿らない。
    ///
    /// 要件 6.1:
    /// - 隠しファイル（.gitignore, .mise.toml 等）は含める
    /// - `.gitignore` 対象はデフォルトで除外
    /// - `includeIgnored=true`（Cmd+P の「ignore も含める」トグル ON）のときは全部含める
    ///
    /// Git repo かつ `includeIgnored=false` のときは `git ls-files` に寄せる（独自 BFS より
    /// `.gitignore` の再現性が高く、ファイル単位の ignore も効く）。それ以外は従来の BFS。
    nonisolated private static func scan(root: URL, includeIgnored: Bool) -> [Entry] {
        let rootPath = root.standardizedFileURL.path
        if !includeIgnored, let viaGit = scanViaGit(root: root, rootPath: rootPath) {
            return viaGit
        }
        return scanViaBFS(root: root, includeIgnored: includeIgnored, rootPath: rootPath)
    }

    /// Git repo では `git ls-files -co --exclude-standard -z` でファイル一覧を取得し、
    /// 親ディレクトリを合成して `Entry` を組む。非 git repo（exit 128 等）では nil を返す。
    /// `.git` 配下は `git ls-files` がそもそも列挙しないので明示の除外は不要。
    nonisolated private static func scanViaGit(root: URL, rootPath: String) -> [Entry]? {
        guard let git = BinaryLocator.git else { return nil }
        let result = ProcessRunner.run(
            executable: git,
            arguments: ["ls-files", "-co", "--exclude-standard", "-z"],
            cwd: root,
            timeout: 10,
            maxStdoutBytes: 16 * 1024 * 1024
        )
        guard result.exitCode == 0 else { return nil }  // 128 = 非 git repo など

        var entries: [Entry] = []
        var seenDirs = Set<String>()  // 合成済みディレクトリの相対パス
        for chunk in result.stdout.split(separator: 0) {
            let rel = String(decoding: chunk, as: UTF8.self)
            guard !rel.isEmpty else { continue }
            // 親ディレクトリを root 直下まで合成
            let components = rel.split(separator: "/").map(String.init)
            if components.count > 1 {
                var acc = ""
                for comp in components.dropLast() {
                    acc = acc.isEmpty ? comp : acc + "/" + comp
                    if seenDirs.insert(acc).inserted {
                        appendEntry(&entries, url: root.appendingPathComponent(acc), isDir: true, rootPath: rootPath)
                    }
                }
            }
            appendEntry(&entries, url: root.appendingPathComponent(rel), isDir: false, rootPath: rootPath)
            if entries.count > 50000 { break }
        }
        return entries
    }

    /// 従来の BFS スキャン（非 git repo / `includeIgnored=true` 用）。
    /// 各レベルのディレクトリ群を `git check-ignore` に一括投入する。
    nonisolated private static func scanViaBFS(root: URL, includeIgnored: Bool, rootPath: String) -> [Entry] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let resourceKeySet = Set(resourceKeys)

        // .git は何が起きても降下しない（巨大かつ検索結果にも出すべきでない）。
        // それ以外の典型的な巨大物 (node_modules 等) は includeIgnored=false の高速ショートカット。
        let alwaysSkipDirNames: Set<String> = [".git"]
        let cheapSkipDirNames: Set<String> = ["node_modules", "DerivedData", ".build"]

        var result: [Entry] = []
        var queue: [URL] = [root]

        outer: while !queue.isEmpty {
            let currentLevel = queue
            queue.removeAll(keepingCapacity: true)

            var dirsForCheck: [URL] = []
            var filesToAdd: [URL] = []

            for parent in currentLevel {
                guard let children = try? fm.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsPackageDescendants]
                ) else { continue }

                for url in children {
                    let values = try? url.resourceValues(forKeys: resourceKeySet)
                    if values?.isSymbolicLink == true { continue }
                    let isDir = values?.isDirectory ?? false
                    if isDir {
                        let name = url.lastPathComponent
                        if alwaysSkipDirNames.contains(name) { continue }
                        if !includeIgnored, cheapSkipDirNames.contains(name) { continue }
                        dirsForCheck.append(url)
                    } else {
                        filesToAdd.append(url)
                    }
                }
            }

            // includeIgnored=true のときは check-ignore を呼ばず全降下。
            let ignored: Set<FilePathKey> = includeIgnored
                ? []
                : GitIgnoreChecker.check(in: root, paths: dirsForCheck)

            for url in dirsForCheck {
                if !includeIgnored, ignored.contains(FilePathKey(url)) { continue }
                appendEntry(&result, url: url, isDir: true, rootPath: rootPath)
                queue.append(url)
                if result.count > 50000 { break outer }
            }

            for url in filesToAdd {
                appendEntry(&result, url: url, isDir: false, rootPath: rootPath)
                if result.count > 50000 { break outer }
            }
        }

        return result
    }

    nonisolated private static func appendEntry(
        _ result: inout [Entry],
        url: URL,
        isDir: Bool,
        rootPath: String
    ) {
        let absolute = url.standardizedFileURL.path
        guard absolute.hasPrefix(rootPath + "/") else { return }
        let relative = String(absolute.dropFirst(rootPath.count + 1))
        result.append(Entry(
            url: url,
            isDirectory: isDir,
            relativePath: relative,
            lowercaseRelativePath: relative.lowercased(),
            lowercaseName: url.lastPathComponent.lowercased()
        ))
    }
}
