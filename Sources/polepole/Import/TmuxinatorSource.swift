import Foundation

/// `~/.tmuxinator/*.yml` を列挙し、各 YAML の `root:` フィールドを抽出する。
///
/// - quote (`'...'` / `"..."`) を剥がす
/// - `#` 以降のコメントを切る
/// - 行に `<%= ... %>` を含むなら ERB と見なしてスキップ
/// - `$VAR` 形式の環境変数は展開しない（失敗時スキップ）
/// - `~` 展開
/// - 最終的に実在するパスだけ返す
struct TmuxinatorSource: ImportSource {
    let id = "tmuxinator"
    let displayName = "tmuxinator"

    private let dir: URL

    /// `fixtureRoot == nil` のときは `~/.tmuxinator/` を使う。
    init(fixtureRoot: URL? = nil) {
        if let fixtureRoot {
            self.dir = fixtureRoot
        } else {
            self.dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".tmuxinator", isDirectory: true)
        }
    }

    func discover() async -> [DiscoveredProject] {
        let dirURL = dir
        return await Task.detached(priority: .utility) { () -> [DiscoveredProject] in
            let fm = FileManager.default
            guard fm.fileExists(atPath: dirURL.path) else { return [] }
            guard let entries = try? fm.contentsOfDirectory(at: dirURL,
                                                            includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else {
                return []
            }
            var results: [DiscoveredProject] = []
            var seen = Set<String>()
            for entry in entries {
                let lower = entry.pathExtension.lowercased()
                guard lower == "yml" || lower == "yaml" else { continue }
                if let project = TmuxinatorSource.parseFile(entry, seen: &seen) {
                    results.append(project)
                }
            }
            return results
        }.value
    }

    static func parseFile(_ url: URL, seen: inout Set<String>) -> DiscoveredProject? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let raw = extractRoot(from: text) else { return nil }
        guard let key = PathNormalizer.canonicalKey(raw) else { return nil }
        if seen.contains(key) { return nil }
        seen.insert(key)
        let projectName = url.deletingPathExtension().lastPathComponent
        return DiscoveredProject(
            canonicalKey: key,
            preferredPath: PathNormalizer.expandTilde(raw),
            displayName: projectName,
            isPinned: false,
            lastAccessAt: nil,
            sourceId: "tmuxinator"
        )
    }

    /// `root: <path>` 行を 1 つだけ拾う。
    /// ERB を含む行はスキップ、`$VAR` 形式は今回は展開しない（含む行はスキップ）。
    static func extractRoot(from text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            // YAML key の root: は行頭 (またはインデント) + "root:" の形のみ。array element の "- root:" は対象外。
            guard let match = line.range(of: #"^\s*root\s*:\s*(.+)$"#, options: .regularExpression) else { continue }
            var value = String(line[match]).replacingOccurrences(of: #"^\s*root\s*:\s*"#, with: "", options: .regularExpression)

            // ERB 行はスキップ
            if value.contains("<%") { continue }

            // # コメントを切る（quote 内の # は今回は無視せず常に切る。tmuxinator の root: では quote 内の # は稀）
            if let hash = value.firstIndex(of: "#") {
                value = String(value[..<hash])
            }
            value = value.trimmingCharacters(in: .whitespaces)

            // quote 剥がし
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            // $VAR 展開は今回はサポートしない（含むものはスキップ）
            if value.contains("$") { continue }

            guard !value.isEmpty else { continue }
            return value
        }
        return nil
    }
}
