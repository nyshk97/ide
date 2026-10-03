import Darwin
import Foundation

/// `posix_spawn` で起動した子プロセス 1 個。`ProcessRunner` から `Foundation.Process` の代わりに使う。
///
/// `Process` を使わない理由: 子プロセスは親タスクの Mach 例外ポートを継承する。PolePole では
/// libghostty 内の Sentry（breakpad）がタスクの例外ポートを握っており、子の `git` 等が落ちると
/// その例外が PolePole 側の breakpad に届く。breakpad は受け取ったメッセージを処理できないと
/// `exit(1)` で本体ごと終了する（2026-10、Dropbox 配下の `.git/index` を mmap 中に dataless 化されて
/// git が SIGBUS → 直後に PolePole が `exit(1)`、を 3 回観測）。
/// `Process` には spawn 属性を渡す口が無いので、`posix_spawnattr_setexceptionports_np` で
/// 例外ポートを空にして起動する。ReportCrash 用の corpse 通知（`EXC_MASK_CORPSE_NOTIFY`）は残し、
/// 子のクラッシュレポートは従来どおり出るようにする。
final class SpawnedChild: @unchecked Sendable {
    /// 子に継承させない例外。`EXC_MASK_CORPSE_NOTIFY` 以外の全種類。
    private static let resetExceptionMask = exception_mask_t(
        EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_EMULATION
            | EXC_MASK_SOFTWARE | EXC_MASK_BREAKPOINT | EXC_MASK_SYSCALL | EXC_MASK_MACH_SYSCALL
            | EXC_MASK_RPC_ALERT | EXC_MASK_CRASH | EXC_MASK_RESOURCE | EXC_MASK_GUARD
    )

    private static let reapQueue = DispatchQueue(label: "local.d0ne1s.polepole.spawned-child.reap")

    /// waitpid が ECHILD で失敗し（他所で回収済み）、終了状態を取れなかったことを表す番兵。
    private static let unknownStatus = Int32.min

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var waitStatus: Int32?
    private var source: DispatchSourceProcess?
    /// exit を回収したら signal する（`waitForExit` 用。1 度 signal したら signal 状態を保つ）。
    private let exitSemaphore = DispatchSemaphore(value: 0)

    var processIdentifier: pid_t { lock.withLock { pid } }

    /// spawn 済みで、まだ exit を回収していない。
    var isRunning: Bool { lock.withLock { pid != 0 && waitStatus == nil } }

    /// `Process.terminationStatus` と同じ規約: 通常終了なら exit code、シグナル終了ならシグナル番号。
    /// exit 前・回収失敗は `-1`。
    var terminationStatus: Int32 {
        lock.withLock {
            guard let status = waitStatus, status != Self.unknownStatus else { return -1 }
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : signal
        }
    }

    /// 起動する。stdin / stdout / stderr に nil を渡した fd は `/dev/null` につなぐ。
    func spawn(
        executable: String,
        arguments: [String],
        cwd: URL?,
        stdin: Int32?,
        stdout: Int32?,
        stderr: Int32?
    ) throws {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for (fd, target, flags) in [(stdin, STDIN_FILENO, O_RDONLY), (stdout, STDOUT_FILENO, O_WRONLY), (stderr, STDERR_FILENO, O_WRONLY)] {
            if let fd {
                posix_spawn_file_actions_adddup2(&fileActions, fd, target)
            } else {
                posix_spawn_file_actions_addopen(&fileActions, target, "/dev/null", flags, 0)
            }
        }
        if let cwd {
            if #available(macOS 26.0, *) {
                posix_spawn_file_actions_addchdir(&fileActions, cwd.path)
            } else {
                posix_spawn_file_actions_addchdir_np(&fileActions, cwd.path)
            }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT: 上で dup2 した 0〜2 以外の fd は子に渡さない。
        // SETSIGDEF / SETSIGMASK: 親で無視・ブロックしているシグナルを子に持ち越さない（Process と同じ）。
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var allSignals = ~sigset_t(0)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t(0)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setexceptionports_np(
            &attributes,
            Self.resetExceptionMask,
            mach_port_t(MACH_PORT_NULL),
            exception_behavior_t(EXCEPTION_DEFAULT),
            thread_state_flavor_t(THREAD_STATE_NONE)
        )

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // 環境変数は親のものをそのまま渡す（Process の既定と同じ）。
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var childPID: pid_t = 0
        let result = posix_spawn(&childPID, executable, &fileActions, &attributes, argv, envp)
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }

        let source = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: Self.reapQueue)
        lock.withLock {
            pid = childPID
            self.source = source
        }
        // source は exit 回収時に cancel する。それまでは handler が self を保持する（回収漏れで消えないように）。
        source.setEventHandler { self.reap() }
        source.resume()
        // exit 間際に source を登録すると exit イベントが来ないことがある。source だけに頼らず、
        // 回収できるまで間隔を延ばしながら `waitpid(WNOHANG)` でも確かめる（`waitForExit` を呼ばない
        // `ProcessRunner.launchDetached` でも zombie を残さないため、待つ側ではなくここで回す）。
        reap()
        schedulePoll(after: 0.05)
    }

    /// exit を最大 `timeout` 秒待つ。exit を回収できたら `true`。
    func waitForExit(timeout: TimeInterval) -> Bool {
        if exitSemaphore.wait(timeout: .now() + timeout) == .success {
            exitSemaphore.signal()
            return true
        }
        return !isRunning
    }

    func terminate() { send(SIGTERM) }

    func send(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        // 回収済みの pid は再利用されうるので送らない
        guard pid != 0, waitStatus == nil else { return }
        kill(pid, signal)
    }

    private func schedulePoll(after interval: TimeInterval) {
        Self.reapQueue.asyncAfter(deadline: .now() + interval) {
            self.reap()
            if self.isRunning { self.schedulePoll(after: min(interval * 2, 1)) }
        }
    }

    private func reap() {
        lock.lock()
        guard pid != 0, waitStatus == nil else {
            lock.unlock()
            return
        }
        var status: Int32 = 0
        var reaped: pid_t
        var error: Int32 = 0
        repeat {
            reaped = waitpid(pid, &status, WNOHANG)
            error = errno
        } while reaped == -1 && error == EINTR
        // 0: まだ動いている。ECHILD 以外のエラー: 次の poll で再試行する
        if reaped == 0 || (reaped == -1 && error != ECHILD) {
            lock.unlock()
            return
        }
        waitStatus = reaped == pid ? status : Self.unknownStatus
        let source = self.source
        self.source = nil
        lock.unlock()

        source?.cancel()
        exitSemaphore.signal()
    }
}
