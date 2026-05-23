import Foundation

/// 外部コマンドのフルパスを 1 箇所に集約する。
///
/// homebrew / Xcode CLT のどちらでも引けるよう代表的なインストール先を順に探す。
/// 以前は `GitStatusModel` と `GitIgnoreChecker` で `locateGit()` が別実装になっていて
/// 候補パスの優先順位すら食い違っていた（要件 8.1 の「argv 配列で起動」も含めここに寄せる）。
enum BinaryLocator {
    /// `git`。Apple CLT 同梱 (`/usr/bin/git`) よりも homebrew 版を優先する
    /// （新しめの porcelain オプションが効くため）。
    static var git: String? {
        firstExecutable(["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"])
    }

    /// `grep`。Brewfile で GNU grep を入れていれば gnubin を優先（`--exclude-dir` 等の挙動を揃えるため）。
    static var grep: String? {
        firstExecutable([
            "/opt/homebrew/opt/grep/libexec/gnubin/grep",
            "/usr/local/opt/grep/libexec/gnubin/grep",
            "/usr/bin/grep",
        ])
    }

    /// `cursor` CLI（VS Code 系の `code` 相当）。
    static var cursor: String? {
        firstExecutable(["/opt/homebrew/bin/cursor", "/usr/local/bin/cursor"])
    }

    private static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// 外部プロセスの実行結果。
struct ProcessResult {
    /// 終了コード。起動自体に失敗した場合は `-1`。
    let exitCode: Int32
    /// timeout で terminate した場合 `true`。
    let timedOut: Bool
    /// stdout 全体（`maxStdoutBytes` 指定時は上限付近で打ち切られていることがある）。
    let stdout: Data
    /// stderr 全体。
    let stderr: Data
    /// `maxStdoutBytes` を超えて打ち切った場合 `true`。
    let stdoutTruncated: Bool

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// `Process` の起動・timeout・stdout/stderr drain・stdin 供給を 1 箇所にまとめる小さな部品。
///
/// 個別実装で起きていた問題をここで一括して潰す:
/// - stdout / stderr の **両方** を別スレッドで drain → pipe バッファ（macOS で 64KB）詰まりで
///   コマンドが write でブロックして固まる事故を防ぐ。
/// - stdin への供給も別 queue で行い stdout drain と並行させる → `git check-ignore --stdin` の
///   stdin↔stdout 同時バッファ詰まりデッドロックを防ぐ。
/// - timeout で `terminate()`（SIGTERM）、なお生きていれば数秒後に SIGKILL。
/// - `maxStdoutBytes` を超えたら terminate（`grep` が上限を超えても出し続ける問題に対処）。
enum ProcessRunner {
    /// drain したバイト列とフラグを lock 付きで保持する箱。並行クロージャ間で共有するため参照型。
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _data = Data()
        private var _truncated = false

        /// 追記して、`limit` 指定時に上限到達したかを返す。
        func append(_ chunk: Data, limit: Int?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            _data.append(chunk)
            let over = limit.map { _data.count >= $0 } ?? false
            if over { _truncated = true }
            return over
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
        var truncated: Bool { lock.lock(); defer { lock.unlock() }; return _truncated }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() { lock.lock(); _value = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    }

    /// 外部コマンドを同期実行する（バックグラウンド queue から呼ぶこと）。
    nonisolated static func run(
        executable: String,
        arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 10,
        maxStdoutBytes: Int? = nil
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = (stdin != nil) ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        let outSink = Sink()
        let errSink = Sink()
        let timedOut = Flag()
        let group = DispatchGroup()

        // stdout drain
        let outHandle = outPipe.fileHandleForReading
        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = outHandle.availableData
                if chunk.isEmpty { break }
                let over = outSink.append(chunk, limit: maxStdoutBytes)
                if over, process.isRunning {
                    process.terminate()
                    // terminate 後も残りバッファを読み切るためループは継続（EOF で抜ける）
                }
            }
            group.leave()
        }

        // stderr drain
        let errHandle = errPipe.fileHandleForReading
        group.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = errHandle.availableData
                if chunk.isEmpty { break }
                _ = errSink.append(chunk, limit: nil)
            }
            group.leave()
        }

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, timedOut: false, stdout: Data(), stderr: Data(), stdoutTruncated: false)
        }

        // stdin 供給（別 queue で stdout drain と並行）
        if let inPipe, let stdin {
            DispatchQueue.global().async {
                let handle = inPipe.fileHandleForWriting
                handle.write(stdin)
                try? handle.close()
            }
        }

        // timeout 監視: SIGTERM → 数秒後も生きていれば SIGKILL
        let timeoutWork = DispatchWorkItem {
            timedOut.set()
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        process.waitUntilExit()
        timeoutWork.cancel()
        group.wait()

        return ProcessResult(
            exitCode: process.terminationStatus,
            timedOut: timedOut.value,
            stdout: outSink.data,
            stderr: errSink.data,
            stdoutTruncated: outSink.truncated
        )
    }
}
