import Foundation

struct DiscoveredGitRepository: Hashable, Sendable {
    let rootURL: URL
    let relativePath: String
    let isRootRepository: Bool

    var displayPath: String {
        relativePath.isEmpty ? "." : relativePath
    }
}

struct GitWorkspaceLayout: Sendable {
    let workspaceRoot: URL
    let rootRepository: DiscoveredGitRepository?
    let childRepositories: [DiscoveredGitRepository]

    var repositories: [DiscoveredGitRepository] {
        var result: [DiscoveredGitRepository] = []
        if let rootRepository {
            result.append(rootRepository)
        }
        result.append(contentsOf: childRepositories)
        return result
    }

    var childRelativePaths: [String] {
        childRepositories.map(\.relativePath)
    }

    func workspaceRelativePath(for url: URL) -> String? {
        Self.relativePath(from: workspaceRoot, to: url)
    }

    func isInsideChildRepository(relativePath rawRelativePath: String) -> Bool {
        let relativePath = Self.normalizedRelativePath(rawRelativePath)
        guard !relativePath.isEmpty else { return false }
        return childRelativePaths.contains { childRelativePath in
            relativePath == childRelativePath || relativePath.hasPrefix(childRelativePath + "/")
        }
    }

    static func relativePath(from root: URL, to url: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    static func normalizedRelativePath(_ raw: String) -> String {
        var value = raw
        while value.hasPrefix("./") {
            value.removeFirst(2)
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

enum GitRepositoryDiscovery {
    nonisolated static func discover(in workspaceRoot: URL) -> GitWorkspaceLayout {
        let workspaceRoot = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        var candidates: [(url: URL, isRoot: Bool)] = []

        if hasGitMarker(at: workspaceRoot) {
            candidates.append((workspaceRoot, true))
        }

        let fm = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        if let children = try? fm.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants]
        ) {
            for child in children {
                let values = try? child.resourceValues(forKeys: Set(resourceKeys))
                guard values?.isDirectory == true else { continue }
                guard hasGitMarker(at: child) else { continue }
                candidates.append((child.standardizedFileURL.resolvingSymlinksInPath(), false))
            }
        }

        var seenRootPaths = Set<String>()
        var rootRepository: DiscoveredGitRepository?
        var childRepositories: [DiscoveredGitRepository] = []

        for candidate in candidates {
            guard let canonicalRoot = canonicalRepositoryRoot(startingAt: candidate.url) else { continue }
            let standardizedRoot = canonicalRoot.standardizedFileURL.resolvingSymlinksInPath()
            let canonicalPath = standardizedRoot.path
            guard seenRootPaths.insert(canonicalPath).inserted else { continue }

            guard let relativePath = GitWorkspaceLayout.relativePath(from: workspaceRoot, to: standardizedRoot) else {
                continue
            }

            let isRootRepository = canonicalPath == workspaceRoot.path
            let repository = DiscoveredGitRepository(
                rootURL: standardizedRoot,
                relativePath: relativePath,
                isRootRepository: isRootRepository
            )
            if isRootRepository {
                rootRepository = repository
            } else {
                childRepositories.append(repository)
            }
        }

        childRepositories.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return GitWorkspaceLayout(
            workspaceRoot: workspaceRoot,
            rootRepository: rootRepository,
            childRepositories: childRepositories
        )
    }

    private static func hasGitMarker(at directory: URL) -> Bool {
        let marker = directory.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private static func canonicalRepositoryRoot(startingAt directory: URL) -> URL? {
        if let git = BinaryLocator.git {
            let result = ProcessRunner.run(
                executable: git,
                arguments: ["rev-parse", "--show-toplevel"],
                cwd: directory,
                timeout: 5
            )
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0, !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            }
        }

        return hasGitMarker(at: directory) ? directory.standardizedFileURL.resolvingSymlinksInPath() : nil
    }
}
