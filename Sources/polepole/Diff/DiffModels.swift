import Foundation

/// DiffViewer から移植したデータモデル。

enum DiffStage: String, Sendable {
    case unstaged = "Unstaged"
    case staged = "Staged"
}

struct DiffLine: Identifiable, Sendable {
    let id = UUID()
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
    let type: LineType

    enum LineType: Sendable {
        case context
        case addition
        case deletion
    }
}

struct DiffHunk: Identifiable, Sendable {
    let id = UUID()
    let header: String
    let lines: [DiffLine]
}

enum FileChangeType: Equatable, Sendable {
    case modified
    case new
    case deleted
    case renamed(from: String)
}

struct FileDiff: Identifiable, Sendable {
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

struct RepositoryDiff: Identifiable, Sendable {
    let repoPath: URL
    let displayPath: String
    let files: [FileDiff]

    var id: String { repoPath.standardizedFileURL.path }
}
