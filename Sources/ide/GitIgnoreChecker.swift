import Foundation

/// `git check-ignore` でファイル群が ignore 対象かを一括判定する。
///
/// argv 配列で起動（要件 8.1: 外部コマンドは shell 文字列結合せず argv 配列で）。
/// プロジェクトが git リポジトリでない場合は空集合を返す（クラッシュさせない）。
enum GitIgnoreChecker {
    /// 指定パス群のうち ignore 対象のものを返す。
    /// 1 件ずつ git に問い合わせるとプロセス起動コストが嵩むので、stdin にまとめて流す。
    static func check(in repoRoot: URL, paths: [URL]) -> Set<URL> {
        guard !paths.isEmpty else { return [] }
        guard let git = locateGit() else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.currentDirectoryURL = repoRoot
        // --no-index で work tree 配下にないファイルでも判定可能。-z は NUL 区切り入出力。
        // --stdin で標準入力からパスを受け取る。
        process.arguments = ["check-ignore", "--stdin", "-z", "--non-matching", "--verbose"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return []
        }

        // パスは NUL 区切りで repoRoot からの相対パスを流す。
        let rootPath = repoRoot.standardizedFileURL.path
        var inputData = Data()
        for url in paths {
            let absolute = url.standardizedFileURL.path
            let relative: String
            if absolute == rootPath {
                continue  // ルート自身は ignore 判定対象外
            } else if absolute.hasPrefix(rootPath + "/") {
                relative = String(absolute.dropFirst(rootPath.count + 1))
            } else {
                continue
            }
            if let bytes = relative.data(using: .utf8) {
                inputData.append(bytes)
                inputData.append(0)
            }
        }
        stdin.fileHandleForWriting.write(inputData)
        try? stdin.fileHandleForWriting.close()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // exit 0/1/128: それぞれ「全 ignore」「全 non-match」「非 git」など。出力内容で判定する。

        // verbose --non-matching の出力フォーマット（NUL 区切り）:
        //   <source>\0<linenum>\0<pattern>\0<path>\0  ... 繰り返し
        // ignore 対象は <source> が空でない。non-match は <source> が空。
        return parseVerboseNullOutput(outData, repoRoot: repoRoot)
    }

    private static func parseVerboseNullOutput(_ data: Data, repoRoot: URL) -> Set<URL> {
        var result: Set<URL> = []
        let bytes = [UInt8](data)
        var fields: [String] = []
        var current: [UInt8] = []
        for b in bytes {
            if b == 0 {
                fields.append(String(decoding: current, as: UTF8.self))
                current = []
                if fields.count == 4 {
                    let source = fields[0]
                    let path = fields[3]
                    if !source.isEmpty {
                        let abs = repoRoot.appendingPathComponent(path).standardizedFileURL
                        result.insert(abs)
                    }
                    fields = []
                }
            } else {
                current.append(b)
            }
        }
        return result
    }

    /// `git` のフルパス。homebrew / Xcode CLT のどちらでも引けるよう PATH を探す。
    private static func locateGit() -> String? {
        let candidates = ["/opt/homebrew/bin/git", "/usr/bin/git", "/usr/local/bin/git"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
