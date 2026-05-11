import Foundation

/// アプリのデータ/ログのサブディレクトリ名を Bundle ID から決める。
///
/// Debug ビルドは Bundle ID が `.dev` で終わるので、Release（Brew 配布版）と
/// `~/Library/Application Support/` `~/Library/Logs/` の中で隣り合うサブディレクトリに
/// 分離される。これにより両方を同時起動してもデータが干渉しない。
enum AppPaths {
    /// `ide` または `ide-dev`。
    static var subdirName: String {
        if let id = Bundle.main.bundleIdentifier, id.hasSuffix(".dev") {
            return "ide-dev"
        }
        return "ide"
    }
}
