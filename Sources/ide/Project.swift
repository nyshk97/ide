import Foundation

/// IDE が扱うプロジェクト 1 つを表す値型。
/// 永続化は step3 で。step2 ではインメモリで生存する。
struct Project: Identifiable, Hashable {
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
}
