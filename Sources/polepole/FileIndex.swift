import Foundation
import SwiftUI

/// プロジェクト 1 つ分のファイル + ディレクトリインデックス。
///
/// 初期構築は project 起動時に再帰スキャン（バックグラウンド queue で実行）。
/// 大規模リポジトリでも 1〜数秒で済む程度の軽い処理として実装。
@MainActor
final class FileIndex: ObservableObject {
    let project: Project

    /// インデックス済みのエントリ（ファイルとディレクトリ両方）。
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isBuilding: Bool = false

    /// 直近開いたファイルのパス → 開いた時刻。スコアリング上位に効かせる。
    var recents: [FilePathKey: Date] = [:]

    struct Entry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        /// project root からの相対パス（小文字化済みは検索用に別保持）
        let relativePath: String
        let lowercaseRelativePath: String
        let lowercaseName: String
        var id: URL { url }
    }

    /// project root を再帰監視する FSEvents watcher。
    /// `nonisolated(unsafe)` で deinit から release できるようにする。
    nonisolated(unsafe) private var watcher: DirectoryChangeWatcher?

    /// rebuild 中に来た event を 1 回にまとめるフラグ。
    private var pendingRebuild = false
    /// 直近 rebuild の完了時刻。短時間に連続 rebuild するのを防ぐのに使う。
    private var lastRebuildFinishedAt: Date = .distantPast
    /// rebuild の最短間隔。`git checkout` / `mise run build` で event ストームが
    /// 起きても秒間 1 回未満に抑える。
    private let minRebuildInterval: TimeInterval = 2.0

    init(project: Project) {
        self.project = project
        // **先に** watcher を張ってから初回 rebuild する。
        // sinceNow で stream を張る都合上、rebuild の前に start しておかないと
        // 「scan 中に作成されたファイル」を取りこぼす。
        // watcher.start() は queue.sync で同期完了するので、return 後は stream 起動済み。
        let w = DirectoryChangeWatcher(root: project.path) { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestRebuild(reason: "fsevents")
            }
        }
        w.start()
        self.watcher = w
        requestRebuild(reason: "initial")
    }

    deinit {
        // 明示 stop() で FSEvents stream を release する。
        // context.retain を使っているので、stop() を呼ばないと watcher 自身が
        // FSEvents から strong ref で握られ続け deinit が走らない。
        watcher?.stop()
    }

    /// rebuild の入口。in-flight / クールダウン中はスキップ or 予約。
    private func requestRebuild(reason: String) {
        if isBuilding {
            pendingRebuild = true
            return
        }
        let elapsed = Date().timeIntervalSince(lastRebuildFinishedAt)
        if elapsed < minRebuildInterval {
            let delay = minRebuildInterval - elapsed
            pendingRebuild = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if self.pendingRebuild && !self.isBuilding {
                    self.pendingRebuild = false
                    self.rebuild(reason: reason)
                }
            }
            return
        }
        rebuild(reason: reason)
    }

    /// 手動 reload (Cmd+R / 🔄 等) 用の public 入口。
    /// `requestRebuild` に通すことで in-flight 中の並列 scan race を防ぐ。
    func rebuild() {
        requestRebuild(reason: "manual")
    }

    private func rebuild(reason: String) {
        isBuilding = true
        let root = project.path
        Logger.shared.debug("[fsevents] rebuild start reason=\(reason)")
        Task.detached { [weak self] in
            let entries = Self.scan(root: root)
            await MainActor.run {
                guard let self else { return }
                self.entries = entries
                self.isBuilding = false
                self.lastRebuildFinishedAt = Date()
                Logger.shared.debug("[fsevents] rebuild end entries=\(entries.count)")
                // rebuild 中に来た event を反映するため、pending があれば再キック
                if self.pendingRebuild {
                    self.pendingRebuild = false
                    self.requestRebuild(reason: "pending")
                }
            }
        }
    }

    /// クエリに対する上位 N 件をスコア降順で返す。
    /// スラッシュを含むクエリはパスマッチに自動切替（lowercaseRelativePath で部分一致）。
    func search(_ query: String, limit: Int = 60) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            // 空クエリ: 直近開いたものを上位に並べる
            return entries.sorted { lhs, rhs in
                let l = recents[FilePathKey(lhs.url)] ?? .distantPast
                let r = recents[FilePathKey(rhs.url)] ?? .distantPast
                return l > r
            }.prefix(limit).map { $0 }
        }

        if q.contains("/") {
            // パスマッチ: 部分一致 + 連続文字優先
            return entries
                .compactMap { e -> (Entry, Int)? in
                    guard e.lowercaseRelativePath.contains(q) else { return nil }
                    var score = 1000
                    if e.lowercaseRelativePath.hasPrefix(q) { score += 500 }
                    if let r = recents[FilePathKey(e.url)] {
                        score += Int(r.timeIntervalSince1970 / 1000)
                    }
                    return (e, score)
                }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { $0.0 }
        }

        // ファジーマッチ: name に対して優先度高め、次にパス全体
        return entries
            .compactMap { e -> (Entry, Int)? in
                let nameScore = fuzzyScore(query: q, target: e.lowercaseName)
                let pathScore = fuzzyScore(query: q, target: e.lowercaseRelativePath) / 2
                let total = max(nameScore, pathScore)
                guard total > 0 else { return nil }
                var score = total
                if let r = recents[FilePathKey(e.url)] {
                    score += Int(r.timeIntervalSince1970 / 1000)
                }
                return (e, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// プレビューを開くたびに呼ぶ。直近スコアに効く。
    func recordOpen(_ url: URL) {
        recents[FilePathKey(url)] = .now
    }

    // MARK: - 内部

    /// 簡易ファジーマッチスコア。
    /// - 各クエリ文字が target 内に「順番通り」現れるかチェックし、隣接ボーナス・先頭ボーナスで加点。
    /// - 1 文字も match しなければ 0 を返す。
    nonisolated private func fuzzyScore(query: String, target: String) -> Int {
        guard !query.isEmpty, !target.isEmpty else { return 0 }
        let qChars = Array(query)
        let tChars = Array(target)
        var qi = 0
        var score = 0
        var lastMatchIdx = -1
        var consecutive = 0
        for (ti, tc) in tChars.enumerated() {
            if qi < qChars.count && tc == qChars[qi] {
                score += 10
                if lastMatchIdx + 1 == ti { consecutive += 1; score += consecutive * 5 } else { consecutive = 0 }
                if ti == 0 { score += 8 }
                lastMatchIdx = ti
                qi += 1
            }
        }
        guard qi == qChars.count else { return 0 }  // 全クエリ文字が含まれることが必要
        return score
    }

    /// project root から再帰スキャン。シンボリックリンクは辿らない。
    ///
    /// 要件 6.1:
    /// - 隠しファイル（.gitignore, .mise.toml 等）は含める
    /// - `.gitignore` 対象は除外（git repo は `git ls-files` 経由で自動的に効く）
    /// - アプリ側で事前定義した [[IgnoredDirectories]]（node_modules / target / __pycache__ 等）も常用除外
    ///
    /// Git repo では `git ls-files` に寄せる（独自 BFS より `.gitignore` の再現性が高く、
    /// ファイル単位の ignore も効く）。非 git repo は BFS で `IgnoredDirectories` を当てる。
    nonisolated private static func scan(root: URL) -> [Entry] {
        let rootPath = root.standardizedFileURL.path
        if let viaGit = scanViaGit(root: root, rootPath: rootPath) {
            return viaGit
        }
        return scanViaBFS(root: root, rootPath: rootPath)
    }

    /// Git repo では `git ls-files -co --exclude-standard -z` でファイル一覧を取得し、
    /// 親ディレクトリを合成して `Entry` を組む。非 git repo（exit 128 等）では nil を返す。
    /// `.git` 配下は `git ls-files` がそもそも列挙しないので明示の除外は不要。
    ///
    /// `git ls-files -c` は **git index に残っているファイル** を返すため、
    /// `rm tracked.txt` した直後の (`git add` で削除を記録していない) ファイルも出る。
    /// FSEvents 経由の rebuild で「削除を反映」したいので、ここで
    /// `FileManager.fileExists` チェックを入れてディスクに無い path は捨てる。
    nonisolated private static func scanViaGit(root: URL, rootPath: String) -> [Entry]? {
        guard let git = BinaryLocator.git else { return nil }
        let result = ProcessRunner.run(
            executable: git,
            arguments: ["ls-files", "-co", "--exclude-standard", "-z"],
            cwd: root,
            timeout: 10,
            maxStdoutBytes: 16 * 1024 * 1024
        )
        guard result.exitCode == 0 else { return nil }  // 128 = 非 git repo など

        let fm = FileManager.default
        var entries: [Entry] = []
        var seenDirs = Set<String>()  // 合成済みディレクトリの相対パス
        for chunk in result.stdout.split(separator: 0) {
            let rel = String(decoding: chunk, as: UTF8.self)
            guard !rel.isEmpty else { continue }

            // ディスクに存在しない path (削除されたが git add していない tracked file) は捨てる
            let fileURL = root.appendingPathComponent(rel)
            guard fm.fileExists(atPath: fileURL.path) else { continue }

            // 親ディレクトリを root 直下まで合成 (存在するファイルの親のみ)
            let components = rel.split(separator: "/").map(String.init)
            if components.count > 1 {
                var acc = ""
                for comp in components.dropLast() {
                    acc = acc.isEmpty ? comp : acc + "/" + comp
                    if seenDirs.insert(acc).inserted {
                        appendEntry(&entries, url: root.appendingPathComponent(acc), isDir: true, rootPath: rootPath)
                    }
                }
            }
            appendEntry(&entries, url: fileURL, isDir: false, rootPath: rootPath)
            if entries.count > 50000 { break }
        }
        return entries
    }

    /// 非 git repo / git ls-files 失敗時の BFS スキャン。
    /// [[IgnoredDirectories]] で事前定義した dir 名を捨てた上で、
    /// 残ったディレクトリ群を `git check-ignore` に一括投入する。
    nonisolated private static func scanViaBFS(root: URL, rootPath: String) -> [Entry] {
        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let resourceKeySet = Set(resourceKeys)

        var result: [Entry] = []
        var queue: [URL] = [root]

        outer: while !queue.isEmpty {
            let currentLevel = queue
            queue.removeAll(keepingCapacity: true)

            var dirsForCheck: [URL] = []
            var filesToAdd: [URL] = []

            for parent in currentLevel {
                guard let children = try? fm.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsPackageDescendants]
                ) else { continue }

                for url in children {
                    let values = try? url.resourceValues(forKeys: resourceKeySet)
                    if values?.isSymbolicLink == true { continue }
                    let isDir = values?.isDirectory ?? false
                    if isDir {
                        if IgnoredDirectories.nameSet.contains(url.lastPathComponent) { continue }
                        dirsForCheck.append(url)
                    } else {
                        filesToAdd.append(url)
                    }
                }
            }

            let ignored = GitIgnoreChecker.check(in: root, paths: dirsForCheck)

            for url in dirsForCheck {
                if ignored.contains(FilePathKey(url)) { continue }
                appendEntry(&result, url: url, isDir: true, rootPath: rootPath)
                queue.append(url)
                if result.count > 50000 { break outer }
            }

            for url in filesToAdd {
                appendEntry(&result, url: url, isDir: false, rootPath: rootPath)
                if result.count > 50000 { break outer }
            }
        }

        return result
    }

    nonisolated private static func appendEntry(
        _ result: inout [Entry],
        url: URL,
        isDir: Bool,
        rootPath: String
    ) {
        let absolute = url.standardizedFileURL.path
        guard absolute.hasPrefix(rootPath + "/") else { return }
        let relative = String(absolute.dropFirst(rootPath.count + 1))
        result.append(Entry(
            url: url,
            isDirectory: isDir,
            relativePath: relative,
            lowercaseRelativePath: relative.lowercased(),
            lowercaseName: url.lastPathComponent.lowercased()
        ))
    }
}
