import Foundation

/// `~/Library/Application Support/ide/projects.json` への永続化担当。
///
/// - schemaVersion: 1
/// - アトミック書き込み（一時ファイル → rename）
/// - バックアップ世代 .1 〜 .3 を保持（save 前にローテーション）
/// - 一時プロジェクトは保存対象外（pin 済みのみ）
struct ProjectsStore: Sendable {
    struct Snapshot: Codable {
        var schemaVersion: Int
        var projects: [Project]
    }

    static let shared = ProjectsStore()

    private var fileManager: FileManager { .default }

    /// 永続化先ディレクトリ。存在しなければ作成。
    var storageDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ide", isDirectory: true)
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
                PocLog.write("[projects] recovered from backup .\(i)")
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
                PocLog.write("[projects] unknown schemaVersion=\(snapshot.schemaVersion) at \(url.lastPathComponent)")
                return nil
            }
            return snapshot.projects
        } catch {
            PocLog.write("[projects] decode failed at \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - Save

    /// pinned のみを保存対象に取る（一時プロジェクトは保存しない）。
    func save(pinned: [Project]) {
        do {
            try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            let snapshot = Snapshot(schemaVersion: 1, projects: pinned)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try atomicWrite(data: data, to: storageURL)
        } catch {
            PocLog.write("[projects] save failed: \(error)")
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
