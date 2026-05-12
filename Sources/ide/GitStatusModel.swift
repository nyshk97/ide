import Foundation
import SwiftUI

/// `git status --porcelain=v1` の結果をファイル単位で保持。
///
/// MVP として 3 秒間隔の Timer ベースで refresh する（FSEvents による即時反映は次フェーズ）。
/// 短時間に複数回 refresh が呼ばれても 200ms debounce で間引く。10 秒タイムアウト付き。
@MainActor
final class GitStatusModel: ObservableObject {
    let project: Project

    /// 絶対パス文字列 → ステータスバッジ。URL 比較は scheme/baseURL の差異で一致しないことが
    /// あるので、`URL.standardizedFileURL.path` を使った String キーで持つ。
    @Published private(set) var statuses: [String: Badge] = [:]

    /// 指定 URL に対するバッジを返す。FileTreeView の row から呼ぶ。
    func badge(for url: URL) -> Badge? {
        statuses[url.standardizedFileURL.path]
    }

    /// `git status` の `XY` 1〜2 文字を UI 用の 1 文字 + 色 にマップ。
    ///
    /// `--ignored` を渡していないので `!!`（ignored）は出力されない。ignored 表示は
    /// `GitIgnoreChecker` → `FileTreeModel.applyIgnored` の薄表示で行う。
    enum Badge: Equatable {
        case modified, added, deleted, untracked, renamed, unknown

        var letter: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .deleted: return "D"
            case .untracked: return "?"
            case .renamed: return "R"
            case .unknown: return "•"
            }
        }
        var color: Color {
            switch self {
            case .modified, .renamed: return .blue
            case .added: return .green
            case .deleted: return .red
            case .untracked: return .secondary
            case .unknown: return .secondary
            }
        }
    }

    nonisolated(unsafe) private var pollTimer: Timer?
    nonisolated(unsafe) private var debounceTimer: Timer?

    init(project: Project) {
        self.project = project
        // 起動時に 1 回 refresh、その後 3 秒間隔で polling
        refreshNow()
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        self.pollTimer = timer
    }

    deinit {
        pollTimer?.invalidate()
        debounceTimer?.invalidate()
    }

    /// 200ms debounce 後に refresh。FileTreeModel.reload や FSEvents 等の経路から呼ぶ。
    func scheduleRefresh() {
        debounceTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        self.debounceTimer = timer
    }

    /// 同期で git status を取って statuses を更新。重い処理だが MVP では single shot で許容。
    func refreshNow() {
        let path = project.path
        // バックグラウンド queue で git を回し、結果は MainActor で反映
        Task.detached { [weak self] in
            let result = Self.runGitStatus(in: path)
            await MainActor.run {
                self?.statuses = result
            }
        }
    }

    /// `git status --porcelain=v1` を 10 秒タイムアウトで実行。
    nonisolated private static func runGitStatus(in repoRoot: URL) -> [String: Badge] {
        guard let git = BinaryLocator.git else { return [:] }
        let result = ProcessRunner.run(
            executable: git,
            arguments: ["status", "--porcelain=v1", "-z", "-uall"],
            cwd: repoRoot,
            timeout: 10
        )
        return parsePorcelainV1(result.stdout, repoRoot: repoRoot)
    }

    /// `--porcelain=v1 -z` 形式の出力をパース。
    nonisolated private static func parsePorcelainV1(_ data: Data, repoRoot: URL) -> [String: Badge] {
        var result: [String: Badge] = [:]
        let bytes = [UInt8](data)
        var idx = 0
        while idx < bytes.count {
            guard idx + 3 <= bytes.count else { break }
            let xy = String(bytes: bytes[idx..<(idx + 2)], encoding: .utf8) ?? "??"
            idx += 3

            var pathBytes: [UInt8] = []
            while idx < bytes.count && bytes[idx] != 0 {
                pathBytes.append(bytes[idx])
                idx += 1
            }
            idx += 1
            let path = String(decoding: pathBytes, as: UTF8.self)

            let badge = badgeFromXY(xy)
            // rename / copy は元ファイル名がもう 1 path 続くのでスキップ
            if xy.hasPrefix("R") || xy.hasPrefix("C") {
                while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
                idx += 1
            }

            let abs = repoRoot.appendingPathComponent(path).standardizedFileURL.path
            result[abs] = badge
        }
        return result
    }

    nonisolated private static func badgeFromXY(_ xy: String) -> Badge {
        let chars = Array(xy)
        guard chars.count >= 2 else { return .unknown }
        let primary = chars[1] != " " ? chars[1] : chars[0]
        switch primary {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        case "?": return .untracked
        default: return .unknown
        }
    }
}
