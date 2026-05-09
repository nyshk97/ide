import Foundation

/// IDE が扱うプロジェクト 1 つを表す値型。
struct Project: Identifiable, Hashable, Codable {
    let id: UUID
    var path: URL
    var displayName: String
    var isPinned: Bool
    var lastOpenedAt: Date

    init(
        id: UUID = UUID(),
        path: URL,
        displayName: String? = nil,
        isPinned: Bool = false,
        lastOpenedAt: Date = .now
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? path.lastPathComponent
        self.isPinned = isPinned
        self.lastOpenedAt = lastOpenedAt
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
        case id, path, displayName, isPinned, lastOpenedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        let pathStr = try c.decode(String.self, forKey: .path)
        self.path = URL(fileURLWithPath: pathStr)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.isPinned = try c.decode(Bool.self, forKey: .isPinned)
        self.lastOpenedAt = try c.decode(Date.self, forKey: .lastOpenedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path.standardizedFileURL.path, forKey: .path)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(isPinned, forKey: .isPinned)
        try c.encode(lastOpenedAt, forKey: .lastOpenedAt)
    }
}
