import Foundation

/// `~/Library/Application Support/ide/projects.json` への永続化担当。
///
/// - schemaVersion: 1
/// - アトミック書き込み（一時ファイル → rename）
/// - バックアップ世代 .1 〜 .3 を保持（save 前にローテーション）
/// - pinned / temporary 両方を保存（明示的に閉じない限り再起動後も残る）。
///   pinned/temporary の区別は Project.isPinned で持っているため、配列としては 1 本にまとめる。
struct ProjectsStore: Sendable {
    struct Snapshot: Codable {
        var schemaVersion: Int
        var projects: [Project]
    }

    static let shared = ProjectsStore()

    private var fileManager: FileManager { .default }

    /// 永続化先ディレクトリ。存在しなければ作成。
    /// Debug ビルドは `ide-dev/` 配下に保存し、Release（Brew 配布版）と完全に分離する。
    var storageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(AppPaths.subdirName, isDirectory: true)
    }

    var storageURL: URL { storageDirectory.appendingPathComponent("projects.json") }

    // MARK: - Load

    /// 起動時にディスクから読む。失敗した場合は最新のバックアップから復旧を試みる。
    func load() -> [Project] {
        let url = storageURL
        if let projects = decode(at: url) {
            return projects
        }
        for i in 1...3 {
            let backup = url.appendingPathExtension("\(i)")
            if let projects = decode(at: backup) {
                Logger.shared.debug("[projects] recovered from backup .\(i)")
                return projects
            }
        }
        return []
    }

    private func decode(at url: URL) -> [Project]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.schemaVersion == 1 else {
                Logger.shared.debug("[projects] unknown schemaVersion=\(snapshot.schemaVersion) at \(url.lastPathComponent)")
                return nil
            }
            return snapshot.projects
        } catch {
            Logger.shared.debug("[projects] decode failed at \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - Save

    /// 渡された全プロジェクトを保存する。pinned / temporary はモデル側で
    /// `Project.isPinned` を見て振り分ける前提なので、ここでは区別しない。
    func save(_ projects: [Project]) {
        do {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let snapshot = Snapshot(schemaVersion: 1, projects: projects)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try atomicWrite(data: data, to: storageURL)
        } catch {
            Logger.shared.debug("[projects] save failed: \(error)")
            DispatchQueue.main.async {
                ErrorBus.shared.notify("Failed to save project list: \(error.localizedDescription)")
            }
        }
    }

    /// 一時ファイルへ書いて rename し、書き込み中の中断による破損を避ける。
    /// rename 前に既存ファイルを .1 にローテーション（→ .2 → .3）する。
    private func atomicWrite(data: Data, to url: URL) throws {
        rotateBackups(of: url)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fileManager.moveItem(at: tmp, to: url)
        }
    }

    /// projects.json -> .1 -> .2 -> .3 にローテーション（.3 は破棄）。
    /// 保存前に呼ぶことで前回保存分を 1 世代下げる。
    private func rotateBackups(of url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let oldest = url.appendingPathExtension("3")
        if fileManager.fileExists(atPath: oldest.path) {
            try? fileManager.removeItem(at: oldest)
        }
        for i in (1...2).reversed() {
            let from = url.appendingPathExtension("\(i)")
            let to = url.appendingPathExtension("\(i + 1)")
            if fileManager.fileExists(atPath: from.path) {
                try? fileManager.moveItem(at: from, to: to)
            }
        }
        let firstBackup = url.appendingPathExtension("1")
        try? fileManager.copyItem(at: url, to: firstBackup)
    }
}
