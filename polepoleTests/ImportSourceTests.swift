import XCTest
@testable import polepole

/// 各 ImportSource の単体テスト。fixture は test 内で tempDir に動的生成する方式（bundle resource 不要）。
final class ImportSourceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polepole-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - PathNormalizer

    func testCanonicalKeyResolvesSymlinks() throws {
        let realDir = tempDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let linkDir = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let viaReal = PathNormalizer.canonicalKey(realDir.path)
        let viaLink = PathNormalizer.canonicalKey(linkDir.path)
        XCTAssertNotNil(viaReal)
        XCTAssertEqual(viaReal, viaLink, "symlink 経由でも canonical key は実体パスに一致するべき")
    }

    func testCanonicalKeyReturnsNilForMissing() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        XCTAssertNil(PathNormalizer.canonicalKey(missing.path))
    }

    func testCanonicalKeyRejectsRegularFiles() throws {
        // Project は常にディレクトリ前提なので、レギュラーファイルは import 対象外。
        let file = tempDir.appendingPathComponent("a-file.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(PathNormalizer.canonicalKey(file.path),
                     "ファイルは canonical key を返さない（dir のみ）")
    }

    // MARK: - ConventionalDirScanSource

    func testConventionalDirScanFindsGitRepos() async throws {
        // ~/ghq 風に 2 階層下に .git を置く
        let root = tempDir.appendingPathComponent("ghq", isDirectory: true)
        let repo1 = root.appendingPathComponent("github.com/foo/bar", isDirectory: true)
        let repo2 = root.appendingPathComponent("github.com/baz/qux", isDirectory: true)
        try FileManager.default.createDirectory(at: repo1.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo2.appendingPathComponent(".git"), withIntermediateDirectories: true)
        // .git の下にはさらに降りない (= nested-repo は無視) ことを検証
        let nested = repo1.appendingPathComponent(".git/modules/inner")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let source = ConventionalDirScanSource(fixtureRoots: [root], maxDepth: 4, timeout: 5.0)
        let results = await source.discover()
        let keys = Set(results.map(\.canonicalKey))
        XCTAssertTrue(keys.contains(PathNormalizer.canonicalKey(repo1.path)!))
        XCTAssertTrue(keys.contains(PathNormalizer.canonicalKey(repo2.path)!))
        XCTAssertEqual(keys.count, 2, ".git 配下まで降りない仕様")
        XCTAssertTrue(results.allSatisfy { $0.sourceId == "ghq" })
    }

    func testConventionalDirScanSkipsMissingRoot() async {
        let source = ConventionalDirScanSource(
            fixtureRoots: [tempDir.appendingPathComponent("not-there")],
            maxDepth: 2,
            timeout: 1.0
        )
        let results = await source.discover()
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - CmuxSessionSource

    func testCmuxSessionParsesWorkspaces() async throws {
        let realA = tempDir.appendingPathComponent("project-a", isDirectory: true)
        let realB = tempDir.appendingPathComponent("project-b", isDirectory: true)
        try FileManager.default.createDirectory(at: realA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realB, withIntermediateDirectories: true)

        let json = """
        {
          "createdAt": 0,
          "version": 1,
          "windows": [{
            "tabManager": {
              "workspaces": [
                {"currentDirectory": "\(realA.path)", "customTitle": "Pinned A", "isPinned": true},
                {"currentDirectory": "\(realB.path)", "customTitle": "B", "isPinned": false},
                {"currentDirectory": "/does/not/exist", "customTitle": null, "isPinned": false}
              ]
            }
          }]
        }
        """
        let sessionPath = tempDir.appendingPathComponent("session.json")
        try json.write(to: sessionPath, atomically: true, encoding: .utf8)

        let source = CmuxSessionSource(fixturePath: sessionPath)
        let results = await source.discover()
        XCTAssertEqual(results.count, 2, "実在しない currentDirectory は捨てる")
        let pinned = try XCTUnwrap(results.first { $0.canonicalKey == PathNormalizer.canonicalKey(realA.path)! })
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(pinned.displayName, "Pinned A")
        XCTAssertEqual(pinned.sourceId, "cmux")
    }

    func testCmuxSessionMissingFileReturnsEmpty() async {
        let source = CmuxSessionSource(fixturePath: tempDir.appendingPathComponent("nope.json"))
        let results = await source.discover()
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - TmuxinatorSource

    func testTmuxinatorExtractsRootEdgeCases() throws {
        let validProject = tempDir.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: validProject, withIntermediateDirectories: true)
        let p = validProject.path

        // Plain
        XCTAssertEqual(TmuxinatorSource.extractRoot(from: "name: foo\nroot: \(p)\n"), p)
        // Double quoted
        XCTAssertEqual(TmuxinatorSource.extractRoot(from: "root: \"\(p)\"\n"), p)
        // Single quoted
        XCTAssertEqual(TmuxinatorSource.extractRoot(from: "root: '\(p)'\n"), p)
        // With comment
        XCTAssertEqual(TmuxinatorSource.extractRoot(from: "root: \(p)   # main\n"), p)
        // ERB → skip
        XCTAssertNil(TmuxinatorSource.extractRoot(from: "root: <%= ENV['HOME'] %>/foo\n"))
        // $VAR → skip
        XCTAssertNil(TmuxinatorSource.extractRoot(from: "root: $HOME/foo\n"))
        // 行頭 root: のみ。"- root:" は対象外
        XCTAssertNil(TmuxinatorSource.extractRoot(from: "windows:\n  - root: foo\n"))
    }

    func testTmuxinatorDiscoverFiltersNonexistent() async throws {
        let dir = tempDir.appendingPathComponent("tmuxinator", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let realProject = tempDir.appendingPathComponent("real-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: realProject, withIntermediateDirectories: true)

        try "name: alive\nroot: \(realProject.path)\n".write(
            to: dir.appendingPathComponent("alive.yml"), atomically: true, encoding: .utf8)
        try "name: dead\nroot: /no/such/path\n".write(
            to: dir.appendingPathComponent("dead.yml"), atomically: true, encoding: .utf8)
        try "name: erb\nroot: <%= ENV['HOME'] %>\n".write(
            to: dir.appendingPathComponent("erb.yml"), atomically: true, encoding: .utf8)
        try "irrelevant: file\n".write(
            to: dir.appendingPathComponent("ignore.txt"), atomically: true, encoding: .utf8)

        let source = TmuxinatorSource(fixtureRoot: dir)
        let results = await source.discover()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.displayName, "alive")
        XCTAssertEqual(results.first?.sourceId, "tmuxinator")
    }

    // MARK: - VSCodeRecentSource

    func testVSCodeStorageExtractsModernWindowsState() async throws {
        // 実機の VS Code / Cursor は openedPathsList を持たず windowsState を使う
        let realA = tempDir.appendingPathComponent("vsa", isDirectory: true)
        let realB = tempDir.appendingPathComponent("vsb", isDirectory: true)
        let realC = tempDir.appendingPathComponent("vsc-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: realA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realC, withIntermediateDirectories: true)

        let json = """
        {
          "windowsState": {
            "lastActiveWindow": {"folder": "file://\(realA.path)"},
            "openedWindows": [{"folder": "file://\(realB.path)"}]
          },
          "backupWorkspaces": {
            "folders": [{"folderUri": "file://\(realC.path)"}]
          }
        }
        """
        let storagePath = tempDir.appendingPathComponent("storage.json")
        try json.write(to: storagePath, atomically: true, encoding: .utf8)

        let source = VSCodeRecentSource.vscode(fixturePath: storagePath)
        let results = await source.discover()
        XCTAssertEqual(results.count, 3, "windowsState + backupWorkspaces をすべて拾う")
        // 配列順は new-first（lastActiveWindow → openedWindows → backupWorkspaces）。
        XCTAssertTrue(results[0].lastAccessAt! > results[1].lastAccessAt!)
        XCTAssertTrue(results[1].lastAccessAt! > results[2].lastAccessAt!)
        // lastActiveWindow の folder が一番新しい
        XCTAssertEqual(results[0].canonicalKey, PathNormalizer.canonicalKey(realA.path))
    }

    func testVSCodeStorageLegacyOpenedPathsList() async throws {
        // 古い VS Code 形式（openedPathsList）も互換で読める
        let real = tempDir.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

        let json = """
        {
          "openedPathsList": {
            "entries": [{"folderUri": "file://\(real.path)"}, {"folderUri": "file:///nope"}]
          }
        }
        """
        let storagePath = tempDir.appendingPathComponent("storage.json")
        try json.write(to: storagePath, atomically: true, encoding: .utf8)

        let source = VSCodeRecentSource.vscode(fixturePath: storagePath)
        let results = await source.discover()
        XCTAssertEqual(results.count, 1)
    }

    func testVSCodeStorageIgnoresFileUriAndNonExistentFolders() async throws {
        // fileUri（単発ファイル）や存在しない folder は無視
        let realFile = tempDir.appendingPathComponent("single.txt")
        try "x".write(to: realFile, atomically: true, encoding: .utf8)

        let json = """
        {
          "windowsState": {
            "lastActiveWindow": {"folder": "file://\(realFile.path)"},
            "openedWindows": [{"folder": "file:///nowhere/at/all"}]
          }
        }
        """
        let storagePath = tempDir.appendingPathComponent("storage.json")
        try json.write(to: storagePath, atomically: true, encoding: .utf8)

        let source = VSCodeRecentSource.vscode(fixturePath: storagePath)
        let results = await source.discover()
        XCTAssertEqual(results.count, 0, "ファイル単体や存在しない folder は捨てる")
    }

    // MARK: - ImportAggregator

    func testAggregatorMergesAcrossSources() async throws {
        let proj = tempDir.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let key = PathNormalizer.canonicalKey(proj.path)!

        let cmuxDiscovery = DiscoveredProject(
            canonicalKey: key, preferredPath: proj.path, displayName: "Shared (cmux title)",
            isPinned: true, lastAccessAt: nil, sourceId: "cmux"
        )
        let ghqDiscovery = DiscoveredProject(
            canonicalKey: key, preferredPath: proj.path, displayName: nil,
            isPinned: false, lastAccessAt: nil, sourceId: "ghq"
        )
        let result = ImportAggregator.merge(
            [cmuxDiscovery, ghqDiscovery],
            existingCanonicalKeys: []
        )
        XCTAssertEqual(result.candidates.count, 1)
        let c = result.candidates.first!
        XCTAssertEqual(Set(c.sources), Set(["cmux", "ghq"]))
        XCTAssertTrue(c.isPinned, "どれかの source で pinned なら OR で true")
        XCTAssertEqual(c.displayName, "Shared (cmux title)")
        XCTAssertTrue(c.defaultSelected, "cmux + cmux pinned + ghq = score 5")
    }

    func testAggregatorSegregatesAlreadyImported() async throws {
        let proj = tempDir.appendingPathComponent("known", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let key = PathNormalizer.canonicalKey(proj.path)!

        let d = DiscoveredProject(
            canonicalKey: key, preferredPath: proj.path, displayName: nil,
            isPinned: false, lastAccessAt: nil, sourceId: "ghq"
        )
        let result = ImportAggregator.merge([d], existingCanonicalKeys: [key])
        XCTAssertEqual(result.candidates.count, 0)
        XCTAssertEqual(result.alreadyImported.count, 1)
    }

    func testAggregatorPrefersHigherPrioritySource() async throws {
        // 実体パスは tempDir 配下、cmux は symlink を経由しているケースを模倣する。
        // 同じ canonical key を持つが preferredPath は別。優先度は cmux > ghq なので cmux の path が残る。
        let realDir = tempDir.appendingPathComponent("real-target", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlink = tempDir.appendingPathComponent("via-symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realDir)
        let key = PathNormalizer.canonicalKey(realDir.path)!

        let cmux = DiscoveredProject(
            canonicalKey: key, preferredPath: symlink.path, displayName: nil,
            isPinned: false, lastAccessAt: nil, sourceId: "cmux"
        )
        let ghq = DiscoveredProject(
            canonicalKey: key, preferredPath: realDir.path, displayName: nil,
            isPinned: false, lastAccessAt: nil, sourceId: "ghq"
        )
        let result = ImportAggregator.merge([ghq, cmux], existingCanonicalKeys: [])
        XCTAssertEqual(result.candidates.first?.preferredPath, symlink.path,
                       "cmux の symlink path が ghq の実体 path より優先される")
    }

    func testAggregatorScoreThreshold() async throws {
        let proj = tempDir.appendingPathComponent("oldvscode", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let key = PathNormalizer.canonicalKey(proj.path)!

        let oldVSCode = DiscoveredProject(
            canonicalKey: key, preferredPath: proj.path, displayName: nil,
            isPinned: false,
            lastAccessAt: Date().addingTimeInterval(-100 * 86400),  // 100日前
            sourceId: "vscode"
        )
        let result = ImportAggregator.merge([oldVSCode], existingCanonicalKeys: [])
        let c = result.candidates.first!
        XCTAssertFalse(c.defaultSelected, "vscode のみ + 90日以上前は score -1 → デフォルト OFF")
    }
}
