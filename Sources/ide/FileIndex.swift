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
    nonisolated private static func scan(root: URL) -> [Entry] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let rootPath = root.standardizedFileURL.path

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [Entry] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            let isSymlink = values?.isSymbolicLink ?? false
            if isSymlink {
                enumerator.skipDescendants()
                continue
            }
            let isDir = values?.isDirectory ?? false
            // 巨大なディレクトリ系は降りない（インデックス膨張を避ける）
            if isDir {
                let name = url.lastPathComponent
                if name == ".git" || name == "node_modules" || name == "DerivedData" || name == ".build" {
                    enumerator.skipDescendants()
                    continue
                }
            }

            let absolute = url.standardizedFileURL.path
            let relative: String
            if absolute.hasPrefix(rootPath + "/") {
                relative = String(absolute.dropFirst(rootPath.count + 1))
            } else {
                relative = absolute
            }
            result.append(Entry(
                url: url,
                isDirectory: isDir,
                relativePath: relative,
                lowercaseRelativePath: relative.lowercased(),
                lowercaseName: url.lastPathComponent.lowercased()
            ))
            if result.count > 50000 { break }  // 安全装置
        }
        return result
    }
}
