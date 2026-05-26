import Foundation

/// VS Code / Cursor の `storage.json` から最近開いた workspace を抽出する。
///
/// 現代の VS Code / Cursor は `openedPathsList` を持たない。実機で確認した schema は:
/// - `windowsState.lastActiveWindow.folder`: `file:///path` URI（最も新しい）
/// - `windowsState.openedWindows[].folder`: 同上
/// - `backupWorkspaces.folders[].folderUri`: 履歴
///
/// 互換のため legacy `openedPathsList.entries[].folderUri` も読む。
/// 配列順を最終 access 順とみなして近似する（新しいほど lastAccessAt を `now` に近く）。
/// `fileUri`（単発ファイル）は project ではないので無視する。
struct VSCodeRecentSource: ImportSource {
    let id: String
    let displayName: String

    private let storagePath: URL

    static func vscode(fixturePath: URL? = nil) -> VSCodeRecentSource {
        VSCodeRecentSource(id: "vscode", displayName: "VS Code",
                           storagePath: fixturePath ?? defaultPath(appName: "Code"))
    }

    static func cursor(fixturePath: URL? = nil) -> VSCodeRecentSource {
        VSCodeRecentSource(id: "cursor", displayName: "Cursor",
                           storagePath: fixturePath ?? defaultPath(appName: "Cursor"))
    }

    private init(id: String, displayName: String, storagePath: URL) {
        self.id = id
        self.displayName = displayName
        self.storagePath = storagePath
    }

    private static func defaultPath(appName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appName)/User/globalStorage/storage.json")
    }

    func discover() async -> [DiscoveredProject] {
        let url = storagePath
        let sourceId = id
        return await Task.detached(priority: .utility) { () -> [DiscoveredProject] in
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return []
            }
            do {
                let storage = try JSONDecoder().decode(VSCodeStorage.self, from: data)
                return VSCodeRecentSource.extract(storage: storage, sourceId: sourceId)
            } catch {
                Logger.shared.warn("[import] vscode storage parse failed (\(sourceId)): \(error)")
                return []
            }
        }.value
    }

    /// 4 つの source（lastActiveWindow / openedWindows / backupWorkspaces / openedPathsList）を
    /// 新しい順とみなして dedup しながら集める。
    static func extract(storage: VSCodeStorage, sourceId: String, now: Date = .now) -> [DiscoveredProject] {
        var orderedRawPaths: [String] = []
        var seenInOrder = Set<String>()

        // 1. lastActiveWindow.folder（最新）
        if let folder = storage.windowsState?.lastActiveWindow?.folder,
           let path = pathFromFileURIString(folder),
           !seenInOrder.contains(path) {
            orderedRawPaths.append(path)
            seenInOrder.insert(path)
        }
        // 2. openedWindows[].folder（current session）
        for w in storage.windowsState?.openedWindows ?? [] {
            if let folder = w.folder,
               let path = pathFromFileURIString(folder),
               !seenInOrder.contains(path) {
                orderedRawPaths.append(path)
                seenInOrder.insert(path)
            }
        }
        // 3. backupWorkspaces.folders[].folderUri（履歴）
        for f in storage.backupWorkspaces?.folders ?? [] {
            if let uri = f.folderUri,
               let path = pathFromFileURIString(uri),
               !seenInOrder.contains(path) {
                orderedRawPaths.append(path)
                seenInOrder.insert(path)
            }
        }
        // 4. legacy openedPathsList.entries[].folderUri（古い VS Code）
        for e in storage.openedPathsList?.entries ?? [] {
            if let uri = e.folderUri,
               let path = pathFromFileURIString(uri),
               !seenInOrder.contains(path) {
                orderedRawPaths.append(path)
                seenInOrder.insert(path)
            }
        }

        // canonical key は directory チェックを通すので、file 単体や存在しない path はここで落ちる
        var seenKeys = Set<String>()
        var out: [DiscoveredProject] = []
        for (index, raw) in orderedRawPaths.enumerated() {
            guard let key = PathNormalizer.canonicalKey(raw) else { continue }
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)
            let lastAccess = now.addingTimeInterval(TimeInterval(-index) * 86400)
            out.append(DiscoveredProject(
                canonicalKey: key,
                preferredPath: raw,
                displayName: nil,
                isPinned: false,
                lastAccessAt: lastAccess,
                sourceId: sourceId
            ))
        }
        return out
    }

    /// `file:///Users/.../foo` → `/Users/.../foo` 変換。
    /// パーセントエンコードはデコード、相対 URL や非 file:// は捨てる。
    static func pathFromFileURIString(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.scheme == "file" else { return nil }
        return url.path
    }
}

// MARK: - JSON モデル（storage.json の最小 subset）
// VS Code / Cursor の現代 schema (windowsState / backupWorkspaces) と
// レガシー (openedPathsList) の両方をカバー。

struct VSCodeStorage: Decodable {
    let windowsState: WindowsState?
    let backupWorkspaces: BackupWorkspaces?
    let openedPathsList: OpenedPathsList?

    struct WindowsState: Decodable {
        let lastActiveWindow: Window?
        let openedWindows: [Window]?
    }

    struct Window: Decodable {
        let folder: String?
    }

    struct BackupWorkspaces: Decodable {
        let folders: [Folder]?

        struct Folder: Decodable {
            let folderUri: String?
        }
    }

    struct OpenedPathsList: Decodable {
        let entries: [Entry]?

        struct Entry: Decodable {
            let folderUri: String?
        }
    }
}
