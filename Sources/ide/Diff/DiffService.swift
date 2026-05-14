import Foundation

/// DiffViewer の `GitService` を IDE に移植したもの。
///
/// 元実装との違い:
/// - 単一 repo 対象（`fetchDiffs(repoPath:)` が `[FileDiff]` を直接返す。`Config` / `RepositoryDiff` 経由ではない）
/// - `Process` 直叩きから `ProcessRunner` + `BinaryLocator.git` 経由に差し替え（10 秒タイムアウト、stdout/stderr drain、SIGTERM → SIGKILL）
enum DiffService {
    /// 指定 repo の全 diff を 1 リストで返す。unstaged + staged + untracked + deleted + rename をマージ。
    nonisolated static func fetchDiffs(repoPath: URL) -> [FileDiff] {
        let path = repoPath
        let unstagedFiles = parseDiff(runGit(["diff", "-M"], at: path), stage: .unstaged)
        let stagedFiles = parseDiff(runGit(["diff", "--staged", "-M"], at: path), stage: .staged)
        let diffFileNames = Set((unstagedFiles + stagedFiles).map { $0.fileName })
        let deletedFiles = fetchDeletedFiles(at: path).filter { !diffFileNames.contains($0.fileName) }
        let untrackedFiles = fetchUntrackedFiles(at: path)
        let (matched, remainingDeleted, remainingNew) = matchRenames(deleted: deletedFiles, untracked: untrackedFiles)
        return unstagedFiles + stagedFiles + matched + remainingDeleted + remainingNew
    }

    /// FileDiffCard で「ファイル全体表示」を選んだとき用に `-U99999` で全行 diff を取り直す。
    nonisolated static func fetchFullFileDiff(fileName: String, repoPath: URL, stage: DiffStage, changeType: FileChangeType) -> [DiffHunk] {
        let args: [String]
        switch stage {
        case .unstaged:
            args = ["diff", "-U99999", "--", fileName]
        case .staged:
            args = ["diff", "--staged", "-U99999", "--", fileName]
        }

        let output = runGit(args, at: repoPath)
        let files = parseDiff(output, stage: stage)
        if let file = files.first {
            return file.hunks
        }

        // 削除ファイルは diff が空になる場合がある → HEAD の内容を全行 deletion として返す
        if changeType == .deleted {
            let content = runGit(["show", "HEAD:\(fileName)"], at: repoPath)
            guard !content.isEmpty else { return [] }
            let lines = content.components(separatedBy: "\n")
            let diffLines = lines.enumerated().map { index, text in
                DiffLine(oldLineNumber: index + 1, newLineNumber: nil, content: text, type: .deletion)
            }
            return [DiffHunk(header: "@@ -1,\(diffLines.count) +0,0 @@", lines: diffLines)]
        }

        return []
    }

    /// 画像プレビュー用に HEAD 時点のファイル内容を生バイトで取る。
    nonisolated static func showFileData(fileName: String, repoPath: URL) -> Data? {
        guard let git = BinaryLocator.git else { return nil }
        let result = ProcessRunner.run(
            executable: git,
            arguments: ["-c", "core.quotepath=false", "show", "HEAD:\(fileName)"],
            cwd: repoPath,
            timeout: 10
        )
        guard result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return result.stdout
    }

    // MARK: - private

    nonisolated private static func fetchUntrackedFiles(at repoPath: URL) -> [FileDiff] {
        let output = runGit(["ls-files", "--others", "--exclude-standard"], at: repoPath)
        guard !output.isEmpty else { return [] }

        return output.components(separatedBy: "\n").compactMap { line in
            let fileName = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fileName.isEmpty else { return nil }

            let filePath = repoPath.appendingPathComponent(fileName).path
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                let contentLines = content.components(separatedBy: "\n")
                let diffLines = contentLines.enumerated().map { index, text in
                    DiffLine(oldLineNumber: nil, newLineNumber: index + 1, content: text, type: .addition)
                }
                guard !diffLines.isEmpty else { return nil }
                let hunk = DiffHunk(header: "@@ -0,0 +1,\(diffLines.count) @@", lines: diffLines)
                return FileDiff(fileName: fileName, hunks: [hunk], stage: .unstaged, changeType: .new)
            } else {
                let diffLines = [DiffLine(oldLineNumber: nil, newLineNumber: 1, content: "(binary file)", type: .addition)]
                let hunk = DiffHunk(header: "@@ -0,0 +1,1 @@", lines: diffLines)
                return FileDiff(fileName: fileName, hunks: [hunk], stage: .unstaged, changeType: .new)
            }
        }
    }

    nonisolated private static func fetchDeletedFiles(at repoPath: URL) -> [FileDiff] {
        let output = runGit(["ls-files", "--deleted"], at: repoPath)
        guard !output.isEmpty else { return [] }

        return output.components(separatedBy: "\n").compactMap { line in
            let fileName = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fileName.isEmpty else { return nil }
            return FileDiff(fileName: fileName, hunks: [], stage: .unstaged, changeType: .deleted)
        }
    }

    /// 削除ファイルと untracked ファイルで basename が一致するものを rename として扱う。
    /// git 自身の rename 検出が効かないステージ外の rename を拾うためのヒューリスティック。
    nonisolated private static func matchRenames(
        deleted: [FileDiff],
        untracked: [FileDiff]
    ) -> (matched: [FileDiff], remainingDeleted: [FileDiff], remainingNew: [FileDiff]) {
        var remainingDeleted = deleted
        var remainingNew = untracked
        var matched: [FileDiff] = []

        for newFile in untracked {
            guard let deleteIndex = remainingDeleted.firstIndex(where: {
                ($0.fileName as NSString).lastPathComponent == (newFile.fileName as NSString).lastPathComponent
            }) else { continue }

            let deletedFile = remainingDeleted[deleteIndex]
            matched.append(FileDiff(
                fileName: newFile.fileName,
                hunks: newFile.hunks,
                stage: .unstaged,
                changeType: .renamed(from: deletedFile.fileName)
            ))
            remainingDeleted.remove(at: deleteIndex)
            remainingNew.removeAll { $0.fileName == newFile.fileName }
        }

        return (matched, remainingDeleted, remainingNew)
    }

    /// ProcessRunner 経由で git を起動して stdout 文字列を返す。
    nonisolated private static func runGit(_ args: [String], at repoPath: URL) -> String {
        guard let git = BinaryLocator.git else { return "" }
        let result = ProcessRunner.run(
            executable: git,
            arguments: ["-c", "core.quotepath=false"] + args,
            cwd: repoPath,
            timeout: 10
        )
        return result.stdoutString
    }

    private static let hunkHeaderRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
    }()

    nonisolated private static func parseDiff(_ output: String, stage: DiffStage) -> [FileDiff] {
        guard !output.isEmpty else { return [] }

        var files: [FileDiff] = []
        var currentFileName: String?
        var currentRenamedFrom: String?
        var currentIsDeleted = false
        var currentHunks: [DiffHunk] = []
        var currentHunkHeader: String = ""
        var currentLines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            if !currentLines.isEmpty {
                currentHunks.append(DiffHunk(header: currentHunkHeader, lines: currentLines))
                currentLines = []
            }
        }

        func flushFile() {
            flushHunk()
            if let fileName = currentFileName {
                let changeType: FileChangeType
                if let from = currentRenamedFrom {
                    changeType = .renamed(from: from)
                } else if currentIsDeleted {
                    changeType = .deleted
                } else {
                    changeType = .modified
                }
                if !currentHunks.isEmpty || changeType != .modified {
                    files.append(FileDiff(fileName: fileName, hunks: currentHunks, stage: stage, changeType: changeType))
                }
            }
            currentHunks = []
            currentFileName = nil
            currentRenamedFrom = nil
            currentIsDeleted = false
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git") {
                flushFile()
            } else if line.hasPrefix("rename from ") {
                currentRenamedFrom = String(line.dropFirst(12))
            } else if line.hasPrefix("rename to ") {
                currentFileName = String(line.dropFirst(10))
            } else if line.hasPrefix("+++ /dev/null") {
                currentIsDeleted = true
            } else if line.hasPrefix("+++ b/") {
                currentFileName = String(line.dropFirst(6))
            } else if line.hasPrefix("--- a/") {
                if currentFileName == nil {
                    currentFileName = String(line.dropFirst(6))
                }
            } else if line.hasPrefix("--- /dev/null") {
                continue
            } else if line.hasPrefix("@@") {
                flushHunk()
                currentHunkHeader = line
                let numbers = parseHunkHeader(line)
                oldLine = numbers.oldStart
                newLine = numbers.newStart
            } else if line.hasPrefix("+") {
                currentLines.append(DiffLine(oldLineNumber: nil, newLineNumber: newLine, content: String(line.dropFirst()), type: .addition))
                newLine += 1
            } else if line.hasPrefix("-") {
                currentLines.append(DiffLine(oldLineNumber: oldLine, newLineNumber: nil, content: String(line.dropFirst()), type: .deletion))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                currentLines.append(DiffLine(oldLineNumber: oldLine, newLineNumber: newLine, content: String(line.dropFirst()), type: .context))
                oldLine += 1
                newLine += 1
            }
        }

        flushFile()
        return files
    }

    nonisolated private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
        guard let match = hunkHeaderRegex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header),
              let oldStart = Int(header[oldRange]),
              let newStart = Int(header[newRange]) else {
            return (1, 1)
        }
        return (oldStart, newStart)
    }
}
