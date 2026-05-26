import Foundation

/// 1 つの ImportSource が発見したプロジェクト 1 件。
/// 同じ canonical key を持つ複数 source からの結果は ImportAggregator でマージされる。
struct DiscoveredProject {
    /// symlink 解決後の絶対パス（dedup キー）。存在しない場合は source 側で捨てる前提なので non-optional。
    let canonicalKey: String
    /// source が報告した raw path（`~` だけ展開済み）。保存時はこちらを使い、symlink 経由運用を尊重する。
    let preferredPath: String
    /// source が拾った表示名（cmux の customTitle 等）。無ければ nil → フォルダ名フォールバック。
    let displayName: String?
    /// cmux で pin されていた等のヒント。複数 source で衝突したら OR で集約。
    let isPinned: Bool
    /// VS Code recent などで最終アクセス時刻が分かるなら入れる。score 計算と「90d ago」表示に使う。
    let lastAccessAt: Date?
    /// "cmux" / "ghq" / "tmuxinator" / "vscode" 等。ImportSource.id と一致させる。
    let sourceId: String
}

/// 複数 source の DiscoveredProject を canonical key で merge した、UI に出る候補 1 行。
struct ImportCandidate: Identifiable {
    var id: String { canonicalKey }
    /// dedup と既存重複判定にだけ使う。UI には出さない。
    let canonicalKey: String
    /// 保存時に Project.path に使う raw path。
    let preferredPath: String
    /// 表示名（複数 source の中で「フォルダ名と違うもの」を優先採用）。
    let displayName: String?
    /// いずれかの source で pin されていれば true。
    let isPinned: Bool
    /// この候補を発見した source の id 群。バッジ表示に使う。
    let sources: [String]
    /// 最も新しい lastAccessAt（あれば）。
    let lastAccessAt: Date?
    /// スコア式から導いた「デフォルトで ON にするか」。
    let defaultSelected: Bool
}

/// ImportSheet → ProjectsModel.importProjects(_:) の入力。
/// ProjectsStore を直接触らないために、bulk API の入口でこの型に変換する。
struct ImportPayload {
    let preferredPath: String
    let displayName: String?
    let isPinned: Bool
}
