import Foundation

/// DiffViewer から移植したデータモデル。**単一 repo 向けに `RepositoryDiff` は除いている**。
/// IDE の diff overlay はアクティブプロジェクト 1 つだけを対象にするため。

enum DiffStage: String {
    case unstaged = "Unstaged"
    case staged = "Staged"
}

struct DiffLine: Identifiable {
    let id = UUID()
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
    let type: LineType

    enum LineType {
        case context
        case addition
        case deletion
    }
}

struct DiffHunk: Identifiable {
    let id = UUID()
    let header: String
    let lines: [DiffLine]
}

enum FileChangeType: Equatable {
    case modified
    case new
    case deleted
    case renamed(from: String)
}

struct FileDiff: Identifiable {
    let id = UUID()
    let fileName: String
    let hunks: [DiffHunk]
    let stage: DiffStage
    let changeType: FileChangeType

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico", "heic", "heif",
    ]

    var isImageFile: Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return Self.imageExtensions.contains(ext)
    }
}
