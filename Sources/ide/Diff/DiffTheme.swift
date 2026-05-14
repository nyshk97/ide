import SwiftUI

/// DiffViewer から移植した GitHub Dark テーマ。
/// diff overlay の中だけで使う前提なので IDE のローカル名前空間に閉じる。
enum GitHubDark {
    static let background = Color(red: 13/255, green: 17/255, blue: 23/255)
    static let surfaceBackground = Color(red: 22/255, green: 27/255, blue: 34/255)
    static let border = Color(red: 48/255, green: 54/255, blue: 61/255)
    static let text = Color(red: 230/255, green: 237/255, blue: 243/255)
    static let textSecondary = Color(red: 125/255, green: 133/255, blue: 144/255)

    static let additionBackground = Color(red: 63/255, green: 185/255, blue: 80/255).opacity(0.15)
    static let deletionBackground = Color(red: 248/255, green: 81/255, blue: 73/255).opacity(0.15)
    static let additionText = Color(red: 126/255, green: 231/255, blue: 135/255)
    static let deletionText = Color(red: 255/255, green: 161/255, blue: 152/255)

    static let lineNumberText = Color(red: 125/255, green: 133/255, blue: 144/255).opacity(0.6)
    static let sectionHeader = Color(red: 31/255, green: 36/255, blue: 43/255)
    static let fileHeader = Color(red: 22/255, green: 27/255, blue: 34/255)

    static let stagedBadge = Color(red: 63/255, green: 185/255, blue: 80/255)
    static let unstagedBadge = Color(red: 210/255, green: 153/255, blue: 34/255)
}
