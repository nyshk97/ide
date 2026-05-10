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

    /// 直近開いたファイルの URL → 開いた時刻。スコアリング上位に効かせる。
    var recents: [URL: Date] = [:]

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
        Task.detached { [weak self] in
            let entries = Self.scan(root: root)
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
                let l = recents[lhs.url] ?? .distantPast
                let r = recents[rhs.url] ?? .distantPast
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
                    if let r = recents[e.url] {
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
                if let r = recents[e.url] {
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
        recents[url] = .now
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
    /// - `.gitignore` 対象のディレクトリは降下スキップ＋インデックスからも除外
    ///   （ファイル単位の ignore は無視するので `.env` 等はヒットする）
    ///
    /// BFS でレベルごとに処理し、各レベルのディレクトリ群を `git check-ignore` に
    /// 一括投入する（プロセス起動コストを 1 レベル 1 回にまとめる）。
    nonisolated private static func scan(root: URL) -> [Entry] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let resourceKeySet = Set(resourceKeys)
        let rootPath = root.standardizedFileURL.path

        // 名前ベースで即降下スキップする巨大ディレクトリ。
        // `.git` は git check-ignore でも報告されないことがあるため、ここで弾いておく。
        // それ以外もよくある巨大物として check-ignore より先にショートカット。
        let alwaysSkipDirNames: Set<String> = [".git", "node_modules", "DerivedData", ".build"]

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
                        if alwaysSkipDirNames.contains(url.lastPathComponent) { continue }
                        dirsForCheck.append(url)
                    } else {
                        filesToAdd.append(url)
                    }
                }
            }

            // .gitignore 対象のディレクトリは降下も Entry 追加もしない。
            let ignored = GitIgnoreChecker.check(in: root, paths: dirsForCheck)

            for url in dirsForCheck {
                if ignored.contains(url) { continue }
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
