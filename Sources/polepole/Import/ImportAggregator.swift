import Foundation

/// 複数の ImportSource からの DiscoveredProject を canonical key で merge し、
/// UI に出す `ImportCandidate` の配列を組み立てる。
///
/// - 既存 ProjectsModel に既に存在する canonical key は `alreadyImported` に分離する
/// - displayName は「フォルダ名と違うものを優先採用」（cmux の customTitle が居れば優先される）
/// - isPinned は OR 集約（どれかの source で pin されていれば true）
/// - score 計算でデフォルト選択 ON/OFF を決める
struct ImportAggregator {
    /// merge 結果。
    struct Result {
        /// PolePole に未登録の候補（UI のメインリスト）。
        let candidates: [ImportCandidate]
        /// 既に PolePole に登録済みのパスを含む候補（折りたたみで「Already in PolePole (M hidden)」）。
        let alreadyImported: [ImportCandidate]
    }

    /// `existingCanonicalKeys` は ProjectsModel.allOrdered の canonicalKey 集合を渡す。
    static func merge(
        _ discoveries: [DiscoveredProject],
        existingCanonicalKeys: Set<String>,
        now: Date = .now
    ) -> Result {
        // canonical key で grouping
        var grouped: [String: [DiscoveredProject]] = [:]
        for d in discoveries {
            grouped[d.canonicalKey, default: []].append(d)
        }

        var candidates: [ImportCandidate] = []
        var alreadyImported: [ImportCandidate] = []
        for (key, group) in grouped {
            let merged = mergeOneKey(key: key, group: group, now: now)
            if existingCanonicalKeys.contains(key) {
                alreadyImported.append(merged)
            } else {
                candidates.append(merged)
            }
        }

        // 安定順序のため preferredPath で sort（候補リストの並び）
        candidates.sort { $0.preferredPath < $1.preferredPath }
        alreadyImported.sort { $0.preferredPath < $1.preferredPath }
        return Result(candidates: candidates, alreadyImported: alreadyImported)
    }

    /// preferredPath を選ぶときの source 優先順。
    /// cmux は user が実際に開いていたパスを保持しているので最優先（symlink 経由運用を尊重）、
    /// 次に tmuxinator（明示的な root 宣言）、その次に VS Code / Cursor の recent、
    /// 最後に慣習 dir scan の実体パス。
    private static let sourcePriority: [String: Int] = [
        "cmux": 4,
        "tmuxinator": 3,
        "vscode": 2,
        "cursor": 2,
        "ghq": 1,
    ]

    private static func mergeOneKey(key: String, group: [DiscoveredProject], now: Date) -> ImportCandidate {
        // preferredPath は最も優先度の高い source の raw path を採用する。
        // 同優先度は最初に見つかった順。これで「cmux で開いてた symlink パス」が ghq scan の
        // 実体パスに上書きされる事故を防ぐ。
        let preferredPath = group
            .max(by: { (sourcePriority[$0.sourceId] ?? 0) < (sourcePriority[$1.sourceId] ?? 0) })?
            .preferredPath ?? key

        let folderName = (preferredPath as NSString).lastPathComponent
        // フォルダ名と違う displayName を持つ source を優先（cmux customTitle ヒント）。
        let displayName = group
            .compactMap(\.displayName)
            .first { !$0.isEmpty && $0 != folderName }
            ?? group.compactMap(\.displayName).first

        let isPinned = group.contains { $0.isPinned }
        let sources = Array(Set(group.map(\.sourceId))).sorted()
        let lastAccessAt = group.compactMap(\.lastAccessAt).max()

        let score = computeScore(group: group, now: now)
        let defaultSelected = score >= 2

        return ImportCandidate(
            canonicalKey: key,
            preferredPath: preferredPath,
            displayName: displayName,
            isPinned: isPinned,
            sources: sources,
            lastAccessAt: lastAccessAt,
            defaultSelected: defaultSelected
        )
    }

    /// デフォルト選択のスコア式。
    /// cmux: +2 / cmux pinned: +2 / ghq (= ConventionalDirScanSource): +1 /
    /// tmuxinator: +1 / vscode 30d以内: +1 / vscode 90d以上前: -1
    private static func computeScore(group: [DiscoveredProject], now: Date) -> Int {
        var score = 0
        let bySource = Dictionary(grouping: group, by: \.sourceId)
        if let cmux = bySource["cmux"]?.first {
            score += 2
            if cmux.isPinned { score += 2 }
        }
        if bySource["ghq"] != nil { score += 1 }
        if bySource["tmuxinator"] != nil { score += 1 }
        let vscode = bySource["vscode"]?.first ?? bySource["cursor"]?.first
        if let v = vscode, let last = v.lastAccessAt {
            let days = now.timeIntervalSince(last) / 86400
            if days <= 30 { score += 1 }
            else if days >= 90 { score -= 1 }
        }
        return score
    }
}
