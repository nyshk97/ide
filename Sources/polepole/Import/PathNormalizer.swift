import Foundation

/// プロジェクトパスの正規化ユーティリティ。
///
/// `ProjectsModel` の重複判定 / Import の dedup / source 横断のマージで、
/// 同じパスを同じキーで識別するために使う。
///
/// - `canonicalKey(_:)` は symlink を辿った実体パスを返す（dedup 用）。
///   存在しないパスは nil を返す。
/// - `expandTilde(_:)` は `~` だけ展開する（実体に解決しない、表示用 / 保存用）。
enum PathNormalizer {
    /// symlink を解決して標準化した絶対パスを返す（dedup キー）。
    /// **ディレクトリでなければ nil**（Project は常にディレクトリ前提）。
    /// 存在しない or 空文字も nil。
    static func canonicalKey(_ path: String) -> String? {
        let expanded = expandTilde(path)
        guard !expanded.isEmpty else { return nil }
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url.path
    }

    /// URL 版。
    static func canonicalKey(_ url: URL) -> String? {
        canonicalKey(url.path)
    }

    /// `~` を `$HOME` に展開する（実体に解決しない）。
    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
