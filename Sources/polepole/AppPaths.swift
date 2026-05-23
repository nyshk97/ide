import Foundation

/// アプリのデータ/ログのサブディレクトリ名を Bundle ID から決める。
///
/// Debug ビルドは Bundle ID が `.dev` で終わるので、Release（Brew 配布版）と
/// `~/Library/Application Support/` `~/Library/Logs/` の中で隣り合うサブディレクトリに
/// 分離される。これにより両方を同時起動してもデータが干渉しない。
enum AppPaths {
    /// `polepole` または `polepole-dev`。
    static var subdirName: String {
        if let id = Bundle.main.bundleIdentifier, id.hasSuffix(".dev") {
            return "polepole-dev"
        }
        return "polepole"
    }

    /// `~/Library/Caches/{polepole,polepole-dev}/`。クリップボード画像などの一時生成物置き場。
    /// Release/Debug で分離される。
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(subdirName, isDirectory: true)
    }

    /// `~/Library/Application Support/{polepole,polepole-dev}/`。projects.json / shortcuts.json /
    /// trial.json などの永続データ置き場。Release/Debug で分離される。
    static var applicationSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(subdirName, isDirectory: true)
    }
}
