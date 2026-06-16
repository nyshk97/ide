import XCTest
@testable import polepole

final class NestedRepositoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("polepole-nested-repo-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDiscoveryFindsRootAndDirectChildOnly() throws {
        let workspace = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let child = workspace.appendingPathComponent("child-repo", isDirectory: true)
        let grandchild = workspace.appendingPathComponent("not-direct/inner", isDirectory: true)
        try initRepo(at: workspace)
        try initRepo(at: child)
        try initRepo(at: grandchild)
        try write("child-repo\n", to: workspace.appendingPathComponent(".gitignore"))

        let layout = GitRepositoryDiscovery.discover(in: workspace)

        XCTAssertEqual(layout.rootRepository?.relativePath, "")
        XCTAssertEqual(layout.childRepositories.map(\.relativePath), ["child-repo"])
    }

    func testDiscoveryFindsGitFileWorktree() throws {
        let base = tempDir.appendingPathComponent("base", isDirectory: true)
        let workspace = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let worktree = workspace.appendingPathComponent("worktree", isDirectory: true)
        try initRepo(at: base)
        try write("base\n", to: base.appendingPathComponent("README.md"))
        try commitAll(in: base)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try git(["worktree", "add", worktree.path, "HEAD"], in: base)

        let layout = GitRepositoryDiscovery.discover(in: workspace)

        XCTAssertEqual(layout.rootRepository, nil)
        XCTAssertEqual(layout.childRepositories.map(\.relativePath), ["worktree"])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".git").path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

    func testDiscoveryDeduplicatesCanonicalRoots() throws {
        let workspace = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let real = workspace.appendingPathComponent("real", isDirectory: true)
        let alias = workspace.appendingPathComponent("alias", isDirectory: true)
        try initRepo(at: real)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let layout = GitRepositoryDiscovery.discover(in: workspace)

        XCTAssertEqual(layout.childRepositories.count, 1)
        XCTAssertEqual(layout.childRepositories.first?.relativePath, "real")
    }

    func testFileIndexIncludesIgnoredChildRepoAndRemainder() throws {
        let workspace = try makeNestedWorkspace(rootIsGitRepository: true)

        let paths = Set(FileIndex.scan(root: workspace).map(\.relativePath))

        XCTAssertTrue(paths.contains("root.txt"))
        XCTAssertTrue(paths.contains("child-repo/visible.txt"))
        XCTAssertFalse(paths.contains("child-repo/hidden.ignored"))
        XCTAssertFalse(paths.contains("not-direct/inner/inner.txt"), "grandchild repo is not discovered as a child repository")
    }

    func testFileIndexKeepsNonGitWorkspaceRemainder() throws {
        let workspace = try makeNestedWorkspace(rootIsGitRepository: false)

        let paths = Set(FileIndex.scan(root: workspace).map(\.relativePath))

        XCTAssertTrue(paths.contains("root.txt"))
        XCTAssertTrue(paths.contains("plain/notes.txt"))
        XCTAssertTrue(paths.contains("child-repo/visible.txt"))
        XCTAssertTrue(paths.contains("child-two/second.txt"))
        XCTAssertFalse(paths.contains("child-repo/hidden.ignored"))
    }

    func testFullTextSearchUsesSamePolicyAsFileIndex() throws {
        let workspace = try makeNestedWorkspace(rootIsGitRepository: true)

        let childHits = FullTextSearcher.run(query: "needle-child", in: workspace)
        let hiddenHits = FullTextSearcher.run(query: "needle-hidden", in: workspace)
        let rootHits = FullTextSearcher.run(query: "needle-root", in: workspace)

        XCTAssertEqual(childHits.map { relativePath($0.url, from: workspace) }, ["child-repo/visible.txt"])
        XCTAssertEqual(hiddenHits, [])
        XCTAssertEqual(rootHits.map { relativePath($0.url, from: workspace) }, ["root.txt"])
    }

    func testFullTextSearchKeepsNonGitWorkspaceRemainder() throws {
        let workspace = try makeNestedWorkspace(rootIsGitRepository: false)

        let hits = FullTextSearcher.run(query: "needle-plain", in: workspace)

        XCTAssertEqual(hits.map { relativePath($0.url, from: workspace) }, ["plain/notes.txt"])
    }

    func testDiffBadgeStates() throws {
        let clean = tempDir.appendingPathComponent("clean", isDirectory: true)
        try initRepo(at: clean)
        XCTAssertEqual(GitStatusModel.snapshot(in: clean).diffBadgeState, .none)

        let rootOnly = tempDir.appendingPathComponent("root-only", isDirectory: true)
        try initRepo(at: rootOnly)
        try write("root\n", to: rootOnly.appendingPathComponent("root.txt"))
        XCTAssertEqual(GitStatusModel.snapshot(in: rootOnly).diffBadgeState, .rootOnly(count: 1))

        let nested = tempDir.appendingPathComponent("nested", isDirectory: true)
        let child = nested.appendingPathComponent("child-repo", isDirectory: true)
        try initRepo(at: nested)
        try initRepo(at: child)
        try write("child\n", to: child.appendingPathComponent("child.txt"))
        let snapshot = GitStatusModel.snapshot(in: nested)
        XCTAssertEqual(snapshot.diffBadgeState, .includesNestedRepo)
        XCTAssertTrue(snapshot.statuses.keys.contains(child.appendingPathComponent("child.txt").standardizedFileURL.resolvingSymlinksInPath().path))
        XCTAssertFalse(snapshot.statuses.keys.contains(child.standardizedFileURL.resolvingSymlinksInPath().path))
    }

    func testDiffServiceGroupsChildRepositoryAndExcludesItFromRoot() throws {
        let workspace = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let child = workspace.appendingPathComponent("child-repo", isDirectory: true)
        try initRepo(at: workspace)
        try initRepo(at: child)
        try write("root diff\n", to: workspace.appendingPathComponent("root.txt"))
        try write("child diff\n", to: child.appendingPathComponent("child.txt"))

        let sections = DiffService.fetchRepositoryDiffs(workspaceRoot: workspace)
        let root = try XCTUnwrap(sections.first { $0.displayPath == "." })
        let childSection = try XCTUnwrap(sections.first { $0.displayPath == "child-repo" })

        XCTAssertEqual(root.files.map(\.fileName), ["root.txt"])
        XCTAssertEqual(childSection.files.map(\.fileName), ["child.txt"])
    }

    private func makeNestedWorkspace(rootIsGitRepository: Bool) throws -> URL {
        let workspace = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = workspace.appendingPathComponent("child-repo", isDirectory: true)
        let childTwo = workspace.appendingPathComponent("child-two", isDirectory: true)
        let plain = workspace.appendingPathComponent("plain", isDirectory: true)
        let grandchild = workspace.appendingPathComponent("not-direct/inner", isDirectory: true)

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if rootIsGitRepository {
            try initRepo(at: workspace)
            try write("child-repo\n", to: workspace.appendingPathComponent(".gitignore"))
        }
        try initRepo(at: child)
        try initRepo(at: childTwo)
        try initRepo(at: grandchild)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        try write("needle-root\n", to: workspace.appendingPathComponent("root.txt"))
        try write("needle-plain\n", to: plain.appendingPathComponent("notes.txt"))
        try write("*.ignored\n", to: child.appendingPathComponent(".gitignore"))
        try write("needle-child\n", to: child.appendingPathComponent("visible.txt"))
        try write("needle-hidden\n", to: child.appendingPathComponent("hidden.ignored"))
        try write("needle-second\n", to: childTwo.appendingPathComponent("second.txt"))
        try write("needle-inner\n", to: grandchild.appendingPathComponent("inner.txt"))

        return workspace
    }

    private func initRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init"], in: url)
        try git(["config", "user.name", "PolePole Tests"], in: url)
        try git(["config", "user.email", "polepole-tests@example.com"], in: url)
    }

    private func commitAll(in url: URL) throws {
        try git(["add", "."], in: url)
        try git(["commit", "-m", "initial"], in: url)
    }

    @discardableResult
    private func git(_ arguments: [String], in cwd: URL) throws -> ProcessResult {
        guard let git = BinaryLocator.git else {
            throw XCTSkip("git is not available")
        }
        let result = ProcessRunner.run(executable: git, arguments: arguments, cwd: cwd, timeout: 10)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "NestedRepositoryTests.git",
                code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.stderrString)",
                ]
            )
        }
        return result
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        GitWorkspaceLayout.relativePath(from: root, to: url) ?? url.path
    }
}
