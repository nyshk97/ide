import Foundation

/// `git check-ignore` でファイル群が ignore 対象かを一括判定する。
///
/// `ProcessRunner` 経由で argv 配列で起動（要件 8.1）。stdin 供給と stdout 読み取りは
/// `ProcessRunner` 内で並行に行われるので、投入パスが多くても stdin↔stdout デッドロックしない。
/// プロジェクトが git リポジトリでない場合は空集合を返す（クラッシュさせない）。
enum GitIgnoreChecker {
    /// 指定パス群のうち ignore 対象のものを返す。
    /// 1 件ずつ git に問い合わせるとプロセス起動コストが嵩むので、stdin にまとめて流す。
    static func check(in repoRoot: URL, paths: [URL]) -> Set<FilePathKey> {
        guard !paths.isEmpty else { return [] }
        guard let git = BinaryLocator.git else { return [] }

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
        guard !inputData.isEmpty else { return [] }

        // -z は NUL 区切り入出力。--stdin で標準入力からパスを受け取る。
        // --verbose --non-matching で「ignore でないパス」も出力させ、source 欄の有無で判定する。
        let result = ProcessRunner.run(
            executable: git,
            arguments: ["check-ignore", "--stdin", "-z", "--non-matching", "--verbose"],
            cwd: repoRoot,
            stdin: inputData,
            timeout: 10
        )
        // exit 0/1/128: それぞれ「全 ignore」「全 non-match」「非 git」など。出力内容で判定する。
        return parseVerboseNullOutput(result.stdout, repoRoot: repoRoot)
    }

    private static func parseVerboseNullOutput(_ data: Data, repoRoot: URL) -> Set<FilePathKey> {
        // verbose --non-matching の出力フォーマット（NUL 区切り）:
        //   <source>\0<linenum>\0<pattern>\0<path>\0  ... 繰り返し
        // ignore 対象は <source> が空でない。non-match は <source> が空。
        var result: Set<FilePathKey> = []
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
                        result.insert(FilePathKey(repoRoot.appendingPathComponent(path)))
                    }
                    fields = []
                }
            } else {
                current.append(b)
            }
        }
        return result
    }
}
