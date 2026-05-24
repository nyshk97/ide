import Foundation

/// Cmd+P (FileIndex) と Cmd+Shift+F (FullTextSearcher) の双方で
/// 「事前に」スキャン対象から外すディレクトリ名の集合。
///
/// 要件 6.1 で「ignored を含むトグル」を撤去したのに合わせて、`.gitignore` を
/// 持たないプロジェクトでも検索結果を汚さないよう、アプリ側で代表的な
/// build artifact / vendor / cache 系を常用無視する。
///
/// git repo では `git ls-files` 経由で `.gitignore` が効くので追加負担は無し。
/// 非 git repo / git ls-files が失敗した場合の BFS と grep の `--exclude-dir`
/// で使う。
enum IgnoredDirectories {
    /// 検索インデックスからも全文検索からも常に除外する dir 名。
    static let names: [String] = [
        // VCS
        ".git", ".hg", ".svn",
        // Node / フロントエンド
        "node_modules", ".pnpm-store", ".yarn", "bower_components",
        "dist", "build", "out",
        ".next", ".nuxt", ".svelte-kit", ".vite", ".parcel-cache", ".turbo", ".cache",
        // Swift / Xcode
        ".build", "DerivedData",
        // Rust
        "target",
        // Python
        "__pycache__", ".venv", "venv", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
        // Go / Ruby / PHP
        "vendor",
        // JVM
        ".gradle",
        // .NET
        "bin", "obj",
        // IaC
        ".terraform",
        // テスト・カバレッジ
        "coverage",
        // 参考リポジトリ置き場（CLAUDE.md グローバルルール）
        ".refs",
    ]

    /// 高速 lookup 用。BFS の各 child に対して `contains` を引く。
    static let nameSet: Set<String> = Set(names)

    /// `grep --exclude-dir=<name>` 用の引数列。
    static var grepExcludeDirArguments: [String] {
        names.map { "--exclude-dir=\($0)" }
    }
}
