import Foundation

/// cmux のセッションスナップショット `~/Library/Application Support/cmux/session-com.cmuxterm.app.json`
/// から workspace を抽出する。`currentDirectory` / `customTitle` / `isPinned` を保持する。
///
/// - 該当ファイルが無ければ静かに空配列を返す（cmux 未インストールの環境）。
/// - JSON 構造はユーザー実機で実測確認済み（windows[].tabManager.workspaces[]）。
struct CmuxSessionSource: ImportSource {
    let id = "cmux"
    let displayName = "cmux"

    private let path: URL

    /// `fixturePath == nil` のときはユーザーの実セッション JSON を使う。
    init(fixturePath: URL? = nil) {
        if let fixturePath {
            self.path = fixturePath
        } else {
            self.path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/cmux/session-com.cmuxterm.app.json")
        }
    }

    func discover() async -> [DiscoveredProject] {
        let url = path
        return await Task.detached(priority: .utility) { () -> [DiscoveredProject] in
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return []
            }
            do {
                let decoder = JSONDecoder()
                let session = try decoder.decode(CmuxSession.self, from: data)
                return CmuxSessionSource.extract(from: session)
            } catch {
                Logger.shared.warn("[import] cmux session parse failed: \(error)")
                return []
            }
        }.value
    }

    private static func extract(from session: CmuxSession) -> [DiscoveredProject] {
        var seen = Set<String>()
        var out: [DiscoveredProject] = []
        for window in session.windows {
            for ws in window.tabManager.workspaces {
                guard let raw = ws.currentDirectory, !raw.isEmpty,
                      let key = PathNormalizer.canonicalKey(raw) else { continue }
                if seen.contains(key) { continue }
                seen.insert(key)
                out.append(DiscoveredProject(
                    canonicalKey: key,
                    preferredPath: raw,
                    displayName: ws.customTitle?.isEmpty == false ? ws.customTitle : nil,
                    isPinned: ws.isPinned ?? false,
                    lastAccessAt: nil,
                    sourceId: "cmux"
                ))
            }
        }
        return out
    }
}

// MARK: - JSON モデル（cmux session の最小 subset）

private struct CmuxSession: Decodable {
    let windows: [CmuxWindow]
}

private struct CmuxWindow: Decodable {
    let tabManager: CmuxTabManager
}

private struct CmuxTabManager: Decodable {
    let workspaces: [CmuxWorkspace]
}

private struct CmuxWorkspace: Decodable {
    let currentDirectory: String?
    let customTitle: String?
    let isPinned: Bool?
}
