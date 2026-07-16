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
    /// 終了コード。起動自体に失敗した場合や exit を確認できなかった場合は `-1`。
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
/// - stdout / stderr の **両方** を drain → pipe バッファ（macOS で 64KB）詰まりで
///   コマンドが write でブロックして固まる事故を防ぐ。
/// - drain は `readabilityHandler` によるイベント駆動で、**待機中にスレッドを一切占有しない**。
///   ブロッキング read だと、EOF が届かない pipe（write 端 fd の漏洩等）が発生するたびに
///   GCD ワーカースレッドが永久リークし、プール枯渇 → 全外部コマンドがタイムアウトする
///   自己増殖状態に入る（2026-07 のファイルツリーリロードのフリーズの根本原因）。
/// - stdin への供給も別 queue で行い stdout drain と並行させる → `git check-ignore --stdin` の
///   stdin↔stdout 同時バッファ詰まりデッドロックを防ぐ。
/// - timeout 監視は GCD queue に置かず **caller スレッド自身で執行**する。
///   ワーカープールが（stdin write のブロック等で）枯れていても SIGTERM/SIGKILL が必ず発火する。
/// - `maxStdoutBytes` を超えたら terminate（`grep` が上限を超えても出し続ける問題に対処）。
enum ProcessRunner {
    private static let ioQueue = DispatchQueue(label: "local.d0ne1s.polepole.process-runner.io", attributes: .concurrent)

    /// pipe 生成〜`process.run()` の間に別スレッドが spawn すると、`FD_CLOEXEC` 設定前の
    /// write 端 fd がその子プロセスに継承され、子が長寿命だと EOF が永遠に届かなくなる。
    /// ProcessRunner 内の spawn 同士はこの lock で直列化して潰す。
    /// libghostty のシェル spawn 等、外部の spawn 経路とのレースは制御外なので**緩和策**
    /// （残っても実害は当該 1 回の drain 猶予分の遅延に留まる）。
    private static let spawnLock = NSLock()

    private static let drainWarnThrottle = WarnThrottle(interval: 60)

    /// 同一 key の WARN 連発を時間窓で集約する。窓内の最初の 1 件だけ通し、
    /// 以降は抑制してカウント。窓が明けた後の最初の 1 件に抑制件数を添えて通す。
    private final class WarnThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private let interval: TimeInterval
        private var windows: [String: (start: Date, suppressed: Int)] = [:]

        init(interval: TimeInterval) { self.interval = interval }

        /// 出力してよければ「直前の窓で抑制した件数」を返す。抑制すべきなら nil。
        func admit(key: String, now: Date = Date()) -> Int? {
            lock.lock(); defer { lock.unlock() }
            if let window = windows[key], now.timeIntervalSince(window.start) < interval {
                windows[key] = (window.start, window.suppressed + 1)
                return nil
            }
            let suppressed = windows[key]?.suppressed ?? 0
            windows[key] = (now, 0)
            return suppressed
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func set() { lock.lock(); _value = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    }

    /// stdout / stderr 1 本分の drain。
    ///
    /// EOF・drain 猶予切れ・起動失敗の複数経路から `finish()` が競合しても、
    /// ハンドラ解除と `group.leave()` を**ちょうど 1 回だけ**行う状態機械。
    /// finish 後はバッファに追記しない（結果返却後に sink が変わるのを防ぐ）。
    ///
    /// read handle は明示 close しない: timeout 経路の finish はハンドラ実行中と競合しうるので、
    /// close してしまうとハンドラ内の `availableData` が閉じた fd に触れて例外になる。
    /// fd は FileHandle の dealloc（= `run()` の return 時）で閉じる。
    private final class StreamDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var _truncated = false
        private var finished = false
        private let handle: FileHandle
        private let group: DispatchGroup

        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
        var truncated: Bool { lock.lock(); defer { lock.unlock() }; return _truncated }

        init(handle: FileHandle, group: DispatchGroup, limit: Int?, onLimitExceeded: (@Sendable () -> Void)? = nil) {
            self.handle = handle
            self.group = group
            group.enter()
            handle.readabilityHandler = { [weak self] readHandle in
                guard let self, !self.isFinished else { return }
                let chunk = readHandle.availableData
                if chunk.isEmpty {
                    self.finish()  // EOF
                    return
                }
                if self.appendIfActive(chunk, limit: limit) {
                    onLimitExceeded?()
                }
            }
        }

        private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        /// finish 前なら追記して、`limit` 指定時に上限到達したかを返す。
        private func appendIfActive(_ chunk: Data, limit: Int?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return false }
            buffer.append(chunk)
            let over = limit.map { buffer.count >= $0 } ?? false
            if over { _truncated = true }
            return over
        }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            handle.readabilityHandler = nil
            group.leave()
        }
    }

    /// 外部コマンドを同期実行する（バックグラウンド queue から呼ぶこと）。
    ///
    /// - Parameter drainGrace: 子プロセス exit 後、stdout/stderr の EOF（残バッファの配り切り）を
    ///   待つ猶予。write 端が外部プロセスに漏れて EOF が来ない場合はこの秒数で諦めて返す
    ///   （スレッド・ハンドラは残さない）。テストから短縮できるよう注入可能にしてある。
    nonisolated static func run(
        executable: String,
        arguments: [String],
        cwd: URL? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 10,
        maxStdoutBytes: Int? = nil,
        drainGrace: TimeInterval = 2
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        // exit 通知は semaphore で受ける（waitUntilExit を使わないのは、caller スレッドで
        // timeout を執行するため。GCD queue に timeout work を置くとプール枯渇時に発火しない）。
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitSemaphore.signal() }

        let group = DispatchGroup()
        let timedOut = Flag()

        // --- spawn 区間: pipe 生成〜run() を直列化（CLOEXEC レース緩和）---
        spawnLock.lock()

        let outPipe = Pipe()
        let errPipe = Pipe()
        markCloseOnExec(outPipe)
        markCloseOnExec(errPipe)
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = (stdin != nil) ? Pipe() : nil
        if let inPipe {
            markCloseOnExec(inPipe)
            process.standardInput = inPipe
        }

        let outDrain = StreamDrain(
            handle: outPipe.fileHandleForReading,
            group: group,
            limit: maxStdoutBytes,
            onLimitExceeded: { if process.isRunning { process.terminate() } }
        )
        let errDrain = StreamDrain(handle: errPipe.fileHandleForReading, group: group, limit: nil)

        do {
            try process.run()
        } catch {
            spawnLock.unlock()
            outDrain.finish()
            errDrain.finish()
            // fd は pipe / FileHandle の dealloc で閉じる
            return ProcessResult(exitCode: -1, timedOut: false, stdout: Data(), stderr: Data(), stdoutTruncated: false)
        }

        // 子は run() 時点で自分用の fd を複製済み。親側の write 端を閉じないと
        // drain に EOF が永遠に届かない。
        closeIgnoringErrors(outPipe.fileHandleForWriting)
        closeIgnoringErrors(errPipe.fileHandleForWriting)
        if let inPipe { closeIgnoringErrors(inPipe.fileHandleForReading) }

        spawnLock.unlock()

        // stdin 供給（別 queue で stdout drain と並行）。
        // 子が stdin を読まずに 64KB 超で write がブロックしても、timeout kill →
        // read 端 close → EPIPE で必ず解放される（上限 = timeout 秒で有界）。
        if let inPipe, let stdin {
            let writeHandle = inPipe.fileHandleForWriting
            // read 端が全て閉じた pipe への write(2) は EPIPE を返す前に SIGPIPE で
            // プロセスごと落ち得る（Darwin）。fd 単位で抑止して EPIPE として処理する。
            _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
            ioQueue.async {
                writeAllIgnoringErrors(stdin, to: writeHandle)
                closeIgnoringErrors(writeHandle)
            }
        }

        // timeout: SIGTERM → 3 秒後も生きていれば SIGKILL（caller スレッドで執行）
        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            timedOut.set()
            if process.isRunning { process.terminate() }
            if exitSemaphore.wait(timeout: .now() + 3) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = exitSemaphore.wait(timeout: .now() + 2)
            }
        }
        let exited = !process.isRunning

        // drain の EOF 猶予: exit 後もバッファ残量を配り切るまで少し待つ。
        // EOF が来ない pipe はここで諦める（finish はハンドラ解除のみでスレッドは残らない）。
        if group.wait(timeout: .now() + drainGrace) == .timedOut {
            outDrain.finish()
            errDrain.finish()
            logDrainTimeout(
                executable: executable,
                pid: process.processIdentifier,
                exitCode: exited ? process.terminationStatus : -1,
                stdoutBytes: outDrain.data.count,
                stderrBytes: errDrain.data.count
            )
        }

        return ProcessResult(
            exitCode: exited ? process.terminationStatus : -1,
            timedOut: timedOut.value,
            stdout: outDrain.data,
            stderr: errDrain.data,
            stdoutTruncated: outDrain.truncated
        )
    }

    /// `FileHandle.write` は EPIPE で ObjC 例外を投げる（Swift から回復不能）ため使わず、
    /// write(2) で全量書く。EPIPE 等のエラーは打ち切り（子が先に exit した場合の正常系）。
    private static func writeAllIgnoringErrors(_ data: Data, to handle: FileHandle) {
        let fd = handle.fileDescriptor
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard var base = buf.baseAddress else { return }
            var remaining = buf.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written > 0 {
                    base += written
                    remaining -= written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func logDrainTimeout(executable: String, pid: Int32, exitCode: Int32, stdoutBytes: Int, stderrBytes: Int) {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        guard let suppressed = drainWarnThrottle.admit(key: name) else { return }
        let suffix = suppressed > 0 ? " (直近60秒で\(suppressed)件抑制)" : ""
        Logger.shared.warn(
            "[process] stdout/stderr drain timed out executable=\(name) pid=\(pid) exit=\(exitCode) stdoutBytes=\(stdoutBytes) stderrBytes=\(stderrBytes)" + suffix
        )
    }

    private static func markCloseOnExec(_ pipe: Pipe) {
        markCloseOnExec(pipe.fileHandleForReading)
        markCloseOnExec(pipe.fileHandleForWriting)
    }

    private static func markCloseOnExec(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }

    private static func closeIgnoringErrors(_ handle: FileHandle) {
        try? handle.close()
    }
}
