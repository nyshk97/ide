import Foundation

/// ファイルツリー上の 1 ノード。ディレクトリならば children を持つ。
final class FileNode: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    /// シンボリックリンクが指す先（外部参照判定用、ファイル symlink でのみ使用）。
    let symlinkTarget: URL?
    /// 子ノード。ディレクトリの場合のみ意味がある。遅延ロードしないのでスキャン時に確定。
    var children: [FileNode]
    /// `.gitignore` 対象か。トグルでの非表示・薄表示の判定に使う。
    var isIgnored: Bool

    init(
        url: URL,
        isDirectory: Bool,
        isSymlink: Bool,
        symlinkTarget: URL? = nil,
        children: [FileNode] = [],
        isIgnored: Bool = false
    ) {
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.children = children
        self.isIgnored = isIgnored
    }

    /// 拡張子（小文字）。ディレクトリの場合は空文字。
    var ext: String {
        guard !isDirectory else { return "" }
        return url.pathExtension.lowercased()
    }
}
