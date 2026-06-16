import Foundation

/// 全文検索の 1 ヒット。ファイル + 行番号 + 該当行のプレビュー文字列。
struct SearchHit: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let lineNumber: Int
    let lineText: String
}

/// プロジェクト全体に対する全文検索。
///
/// 当初は ripgrep を使う設計（要件 6.2）だが、ripgrep バイナリが未バンドルのため
/// Phase 2 では macOS 標準の `grep -rn` を argv 配列で起動して代用する。
/// 結果上限 1000 件、10 秒タイムアウト（要件通り）。
/// ripgrep へのスイッチは Phase 2.5（バンドリング + entitlements 検証）。
enum FullTextSearcher {
    static let resultLimit = 1000
    static let timeoutSeconds: TimeInterval = 10
    /// stdout の打ち切り上限。grep は結果上限を知らないので、これを超えたら `ProcessRunner` が
    /// terminate する（1000 件分の出力は通常これより遥かに小さい）。
    static let maxStdoutBytes = 4 * 1024 * 1024

    /// 検索を実行（同期、バックグラウンド queue で呼ぶこと）。
    nonisolated static func run(query: String, in repoRoot: URL) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let grep = BinaryLocator.grep else { return [] }

        let root = repoRoot.standardizedFileURL.resolvingSymlinksInPath()
        let filePaths = FileIndex.scan(root: root)
            .filter { !$0.isDirectory }
            .map(\.relativePath)
        guard !filePaths.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for batch in batches(for: filePaths, query: trimmed) {
            let arguments = ["-nIH", "-F", "--", trimmed] + batch
            let result = ProcessRunner.run(
                executable: grep,
                arguments: arguments,
                cwd: root,
                timeout: timeoutSeconds,
                maxStdoutBytes: maxStdoutBytes
            )
            hits.append(contentsOf: parse(result.stdoutString, repoRoot: root, remainingLimit: resultLimit - hits.count))
            if hits.count >= resultLimit { break }
        }
        return Array(hits.prefix(resultLimit))
    }

    nonisolated private static func batches(for paths: [String], query: String) -> [[String]] {
        let maxFilesPerBatch = 200
        let maxArgBytes = 64 * 1024
        let fixedBytes = "-nIH".utf8.count + "-F".utf8.count + "--".utf8.count + query.utf8.count + 4
        var batches: [[String]] = []
        var current: [String] = []
        var currentBytes = fixedBytes

        for path in paths {
            let pathBytes = path.utf8.count + 1
            if !current.isEmpty && (current.count >= maxFilesPerBatch || currentBytes + pathBytes > maxArgBytes) {
                batches.append(current)
                current = []
                currentBytes = fixedBytes
            }
            current.append(path)
            currentBytes += pathBytes
        }

        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    nonisolated private static func parse(_ text: String, repoRoot: URL, remainingLimit: Int) -> [SearchHit] {
        guard remainingLimit > 0 else { return [] }
        var hits: [SearchHit] = []
        for line in text.split(separator: "\n") {
            // 形式: <path>:<line>:<text>
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var pathStr = String(parts[0])
            // 先頭の `./` を取る
            if pathStr.hasPrefix("./") { pathStr = String(pathStr.dropFirst(2)) }
            guard let lineNo = Int(parts[1]) else { continue }
            let snippet = String(parts[2])
            let url: URL
            if pathStr.hasPrefix("/") {
                url = URL(fileURLWithPath: pathStr).standardizedFileURL
            } else {
                url = repoRoot.appendingPathComponent(pathStr).standardizedFileURL
            }
            hits.append(SearchHit(url: url, lineNumber: lineNo, lineText: snippet))
            if hits.count >= remainingLimit { break }
        }
        return hits
    }

}
