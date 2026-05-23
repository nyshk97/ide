import Foundation

/// ファイルパスを「標準化済み path 文字列」で表す比較キー。
///
/// `URL` の `==` は scheme / baseURL / 末尾スラッシュ等の差で一致しないことがあるので
/// （`docs/DEV.md` の既知の罠）、状態キー — 展開状態・プレビュー履歴・ignore 判定・recents など
/// — には `URL` を直接使わずこの型を経由する。
struct FilePathKey: Hashable, Codable, Sendable {
    let path: String

    init(_ url: URL) {
        self.path = url.standardizedFileURL.path
    }

    init(path: String) {
        self.path = path
    }
}
