import Foundation

/// 右側シェルエリアのペイン構成。プロジェクトごとに永続化する。
enum PaneLayout: String, Codable, Hashable {
    /// 上小・下大の 2 ペイン（上下分割）
    case split
    /// 下ペインだけを表示し上ペインは collapse する（1 ペイン）
    case singleBottom
    /// 左右 2 ペイン（topPane が左、bottomPane が右）
    case splitHorizontal
    /// 2×2 の 4 ペイングリッド（topRightPane / bottomRightPane を追加使用）
    case splitFour
}

/// PolePole が扱うプロジェクト 1 つを表す値型。
struct Project: Identifiable, Hashable, Codable {
    let id: UUID
    var path: URL
    var displayName: String
    var isPinned: Bool
    var lastOpenedAt: Date
    /// アバターの色 (`ProjectColor.rawValue`)。nil なら名前から自動決定。
    var colorKey: String?
    /// 右側シェルエリアのペイン構成。デフォルトは `.split`。
    var paneLayout: PaneLayout

    init(
        id: UUID = UUID(),
        path: URL,
        displayName: String? = nil,
        isPinned: Bool = false,
        lastOpenedAt: Date = .now,
        colorKey: String? = nil,
        paneLayout: PaneLayout = .split
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? path.lastPathComponent
        self.isPinned = isPinned
        self.lastOpenedAt = lastOpenedAt
        self.colorKey = colorKey
        self.paneLayout = paneLayout
    }

    /// path がファイルシステム上に存在しないか、ディレクトリでない場合 true。
    /// 一時的なマウント解除でも true になるが、ピン留めは消さない（要件通り）。
    var isMissing: Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
        return !exists || !isDir.boolValue
    }

    // MARK: - Codable
    // URL を path 文字列として保存（フルパス、標準化済み）

    private enum CodingKeys: String, CodingKey {
        case id, path, displayName, isPinned, lastOpenedAt, colorKey, paneLayout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        let pathStr = try c.decode(String.self, forKey: .path)
        self.path = URL(fileURLWithPath: pathStr)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.isPinned = try c.decode(Bool.self, forKey: .isPinned)
        self.lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
        self.colorKey = try c.decodeIfPresent(String.self, forKey: .colorKey)
        // paneLayout は後追い追加なので、旧 JSON 互換のため decodeIfPresent + .split フォールバック
        self.paneLayout = try c.decodeIfPresent(PaneLayout.self, forKey: .paneLayout) ?? .split
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path.standardizedFileURL.path, forKey: .path)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(lastOpenedAt, forKey: .lastOpenedAt)
        try c.encodeIfPresent(colorKey, forKey: .colorKey)
        try c.encode(paneLayout, forKey: .paneLayout)
    }
}
