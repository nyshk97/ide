import Foundation
import SwiftUI

/// EmptyHubView / Settings Import タブから共有して使う scan ハブ。
///
/// 4 source（cmux / ghq / tmuxinator / VS Code / Cursor）を並列で走らせ、
/// ImportAggregator で merge した結果を `result` に流す。
@MainActor
final class ImportScanner: ObservableObject {
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var result: ImportAggregator.Result?
    @Published private(set) var error: String?

    /// scan を 1 回だけ実行する。既に scan 中 / 既に結果がある場合は no-op。
    /// `force == true` のときは強制的に再 scan する。
    func scanIfNeeded(force: Bool = false) async {
        if isScanning { return }
        if !force, result != nil { return }
        await scan()
    }

    func scan() async {
        isScanning = true
        defer { isScanning = false }

        let sources = ImportScanner.makeSources()
        Logger.shared.debug("[import] scan started with \(sources.count) source(s)")

        let discoveries = await withTaskGroup(of: [DiscoveredProject].self) { group in
            for source in sources {
                group.addTask {
                    let s = source
                    let result = await s.discover()
                    Logger.shared.debug("[import] source=\(s.id) found=\(result.count)")
                    return result
                }
            }
            var all: [DiscoveredProject] = []
            for await result in group {
                all.append(contentsOf: result)
            }
            return all
        }

        let existingKeys = Set(ProjectsModel.shared.allOrdered.compactMap {
            PathNormalizer.canonicalKey($0.path)
        })
        let merged = ImportAggregator.merge(discoveries, existingCanonicalKeys: existingKeys)
        self.result = merged
        Logger.shared.info("[import] scan done candidates=\(merged.candidates.count) alreadyImported=\(merged.alreadyImported.count)")
    }

    /// `POLEPOLE_TEST_IMPORT_FIXTURE=<dir>` が立っていれば fixture モードで source を作る。
    /// 期待構造: `<dir>/conventional/`、`<dir>/cmux/session.json`、`<dir>/tmuxinator/`、
    /// `<dir>/vscode/storage.json`、`<dir>/cursor/storage.json`
    static func makeSources() -> [any ImportSource] {
        if let fixture = ProcessInfo.processInfo.environment["POLEPOLE_TEST_IMPORT_FIXTURE"] {
            let base = URL(fileURLWithPath: fixture)
            return [
                ConventionalDirScanSource(fixtureRoots: [base.appendingPathComponent("conventional")]),
                CmuxSessionSource(fixturePath: base.appendingPathComponent("cmux/session.json")),
                TmuxinatorSource(fixtureRoot: base.appendingPathComponent("tmuxinator")),
                VSCodeRecentSource.vscode(fixturePath: base.appendingPathComponent("vscode/storage.json")),
                VSCodeRecentSource.cursor(fixturePath: base.appendingPathComponent("cursor/storage.json")),
            ]
        }
        return [
            ConventionalDirScanSource(),
            CmuxSessionSource(),
            TmuxinatorSource(),
            VSCodeRecentSource.vscode(),
            VSCodeRecentSource.cursor(),
        ]
    }
}
