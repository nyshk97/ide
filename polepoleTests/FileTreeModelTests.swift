import XCTest
@testable import polepole

/// FileTreeModel の `.gitignore` 判定の「後追い反映」まわりのテスト。
///
/// 判定はバックグラウンドで走り結果がメインスレッドに戻ってくるため、
/// `ignoreChecker` を注入して遅延・結果を決定的に制御する。
@MainActor
final class FileTreeModelTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("filetree-tests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: tempDir.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        fm.createFile(atPath: tempDir.appendingPathComponent("root-file.txt").path, contents: nil)
        fm.createFile(atPath: tempDir.appendingPathComponent("subdir/inner-a.txt").path, contents: nil)
        fm.createFile(atPath: tempDir.appendingPathComponent("subdir/inner-b.txt").path, contents: nil)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 条件が満たされるまでメインスレッドを譲りながら待つ（detached → MainActor の hop を進める）。
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func node(named name: String, under parent: FileNode) -> FileNode? {
        parent.children.first { $0.name == name }
    }

    /// ignore 判定結果が後追いで正しい node に反映されること。
    func testIgnoreResultIsAppliedToCorrectNodes() async throws {
        let model = FileTreeModel(project: Project(path: tempDir))
        let ignoredKey = FilePathKey(tempDir.appendingPathComponent("root-file.txt"))
        model.ignoreChecker = { _, paths in
            Set(paths.map(FilePathKey.init).filter { $0 == ignoredKey })
        }
        model.reload()

        try await waitUntil { self.node(named: "root-file.txt", under: model.root)?.isIgnored == true }

        XCTAssertEqual(node(named: "root-file.txt", under: model.root)?.isIgnored, true)
        XCTAssertEqual(node(named: "subdir", under: model.root)?.isIgnored, false)
    }

    /// reload 後に届いた古い世代の ignore 結果が、新しいツリーに反映されないこと。
    func testStaleIgnoreResultFromPreviousGenerationIsDropped() async throws {
        let model = FileTreeModel(project: Project(path: tempDir))

        // 1回目の判定を gate で止め、結果が「全ファイル ignored」で遅れて届く状況を作る
        let gate = DispatchSemaphore(value: 0)
        let callCount = Counter()
        model.ignoreChecker = { _, paths in
            if callCount.increment() == 1 {
                gate.wait()  // バックグラウンドスレッド上なので block してよい
                return Set(paths.map(FilePathKey.init))  // 古い世代: 全部 ignored
            }
            return []  // 新しい世代: ignored なし
        }

        model.reload()  // 世代 N: checker 1回目が gate で停止
        try await waitUntil { callCount.value >= 1 }
        model.reload()  // 世代 N+1: ツリー再構築、checker 2回目は即 [] を返す
        gate.signal()   // 古い世代の結果（全部 ignored）が今さら届く

        try await waitUntil { callCount.value >= 2 }
        // 古い結果が捨てられたことを確認するため、hop が掃けるまで少し待ってから検証
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(node(named: "root-file.txt", under: model.root)?.isIgnored, false,
                       "古い世代の ignore 結果が新しいツリーに反映されている")
        XCTAssertEqual(node(named: "subdir", under: model.root)?.isIgnored, false)
    }

    /// ディレクトリ展開（遅延 scan）直後の ignore 結果が、該当ディレクトリ配下の
    /// 正しい node にだけ反映されること。
    func testExpandAppliesIgnoreOnlyToScannedChildren() async throws {
        let model = FileTreeModel(project: Project(path: tempDir))
        let ignoredKey = FilePathKey(tempDir.appendingPathComponent("subdir/inner-a.txt"))
        model.ignoreChecker = { _, paths in
            Set(paths.map(FilePathKey.init).filter { $0 == ignoredKey })
        }

        let subdirURL = tempDir.appendingPathComponent("subdir")
        model.toggleExpanded(subdirURL)

        guard let subdir = node(named: "subdir", under: model.root) else {
            return XCTFail("subdir node not found")
        }
        try await waitUntil { self.node(named: "inner-a.txt", under: subdir)?.isIgnored == true }

        XCTAssertEqual(node(named: "inner-a.txt", under: subdir)?.isIgnored, true)
        XCTAssertEqual(node(named: "inner-b.txt", under: subdir)?.isIgnored, false)
        XCTAssertEqual(node(named: "root-file.txt", under: model.root)?.isIgnored, false)
    }
}

/// テスト用のスレッドセーフなカウンタ（checker はバックグラウンドから呼ばれる）。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    @discardableResult
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; _value += 1; return _value }
}
