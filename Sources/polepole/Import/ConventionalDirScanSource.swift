import Foundation

/// `~/ghq` `~/src` `~/dev` `~/Projects` `~/Code` 配下を BFS で探索し、
/// `.git` を含むディレクトリを 1 件として返す。`.git` を見つけたらそれより深くは降りない。
///
/// - 全体 timeout は 3 秒。それまでに集めた結果だけ返す。
/// - 各 root は存在しなければ静かにスキップ。
/// - テスト時は `fixtureRoots:` で探索 root を差し替える。
struct ConventionalDirScanSource: ImportSource {
    let id = "ghq"
    let displayName = "Local"

    private let roots: [URL]
    private let maxDepth: Int
    private let timeout: TimeInterval

    /// `fixtureRoots == nil` のときは `~/ghq` ほかの固定 5 パスを使う。
    init(fixtureRoots: [URL]? = nil, maxDepth: Int = 4, timeout: TimeInterval = 3.0) {
        self.maxDepth = maxDepth
        self.timeout = timeout
        if let fixtureRoots {
            self.roots = fixtureRoots
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.roots = ["ghq", "src", "dev", "Projects", "Code"].map {
                home.appendingPathComponent($0, isDirectory: true)
            }
        }
    }

    func discover() async -> [DiscoveredProject] {
        let deadline = Date().addingTimeInterval(timeout)
        return await withTaskGroup(of: [DiscoveredProject].self) { group in
            for root in roots {
                group.addTask {
                    scan(root: root, deadline: deadline)
                }
            }
            var all: [DiscoveredProject] = []
            for await result in group {
                all.append(contentsOf: result)
            }
            return all
        }
    }

    private func scan(root: URL, deadline: Date) -> [DiscoveredProject] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var results: [DiscoveredProject] = []
        // BFS: (url, depth)
        var queue: [(URL, Int)] = [(root, 0)]
        while !queue.isEmpty {
            if Date() > deadline { break }
            let (dir, depth) = queue.removeFirst()

            // .git を含むなら 1 件として記録、それより下は降りない
            let dotGit = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                if let key = PathNormalizer.canonicalKey(dir.path) {
                    results.append(DiscoveredProject(
                        canonicalKey: key,
                        preferredPath: dir.path,
                        displayName: nil,
                        isPinned: false,
                        lastAccessAt: nil,
                        sourceId: id
                    ))
                }
                continue
            }

            guard depth < maxDepth else { continue }
            guard let children = try? fm.contentsOfDirectory(at: dir,
                                                             includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
            for child in children {
                var childIsDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &childIsDir), childIsDir.boolValue {
                    queue.append((child, depth + 1))
                }
            }
        }
        return results
    }
}
