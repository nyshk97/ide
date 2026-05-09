import Foundation

/// 全文検索の 1 ヒット。ファイル + 行番号 + 該当行のプレビュー文字列。
struct SearchHit: Identifiable, Hashable {
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

    /// 検索を実行（同期、バックグラウンド queue で呼ぶこと）。
    nonisolated static func run(query: String, in repoRoot: URL) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let grep = locateGrep() else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: grep)
        process.currentDirectoryURL = repoRoot
        // -r 再帰、-n 行番号、-I バイナリ除外、-F 固定文字列扱い、--exclude-dir で重い dir をスキップ
        process.arguments = [
            "-rnIH",
            "-F",
            "--exclude-dir=.git",
            "--exclude-dir=node_modules",
            "--exclude-dir=DerivedData",
            "--exclude-dir=.build",
            "--exclude-dir=.refs",
            trimmed,
            ".",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch { return [] }

        let deadline = DispatchTime.now() + timeoutSeconds
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text, repoRoot: repoRoot)
    }

    nonisolated private static func parse(_ text: String, repoRoot: URL) -> [SearchHit] {
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
            let url = repoRoot.appendingPathComponent(pathStr).standardizedFileURL
            hits.append(SearchHit(url: url, lineNumber: lineNo, lineText: snippet))
            if hits.count >= resultLimit { break }
        }
        return hits
    }

    nonisolated private static func locateGrep() -> String? {
        // GNU grep 優先（Brewfile で grep をインストールしていれば /usr/local/opt/grep/libexec/gnubin/grep）
        let candidates = [
            "/opt/homebrew/opt/grep/libexec/gnubin/grep",
            "/usr/local/opt/grep/libexec/gnubin/grep",
            "/usr/bin/grep",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
