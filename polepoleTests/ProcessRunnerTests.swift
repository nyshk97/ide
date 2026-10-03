import XCTest
@testable import polepole

final class ProcessRunnerTests: XCTestCase {
    // MARK: - EOF 不達（write 端を子孫プロセスが握り続ける）

    /// 子孫が stdout の write 端を握り続けても、drain 猶予経過後に結果が返る（ハングしない）。
    func testRunReturnsWhenDescendantKeepsStdoutOpen() {
        let start = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf done; (sleep 3) &"],
            timeout: 5,
            drainGrace: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "done")
        XCTAssertLessThan(elapsed, 2.5)
    }

    /// EOF 不達タイムアウトを連発させても、スレッド/ハンドラをリークせず後続呼び出しが健全なこと。
    /// 旧実装（ブロッキング availableData ループ）はタイムアウトごとに GCD ワーカーを
    /// 最大2本永久リークし、プール枯渇後は全呼び出しが stdoutBytes=0 でタイムアウトしていた。
    func testConsecutiveDrainTimeoutsDoNotDegradeSubsequentRuns() {
        for _ in 0..<20 {
            let result = ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf x; (sleep 3) &"],
                timeout: 5,
                drainGrace: 0.2
            )
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.stdoutString, "x")
        }

        // 直後の正常な呼び出しが「速く・正しく読めて」いれば非リークの証明になる
        let start = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello"],
            timeout: 5,
            drainGrace: 2
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "hello")
        XCTAssertLessThan(elapsed, 1.0, "正常呼び出しが遅い = drain がイベント駆動で動いていない可能性")
    }

    // MARK: - stdin の安全性

    /// stdin を読まない子に pipe 容量（64KB）超の stdin を渡しても、
    /// timeout kill → read 端 close → EPIPE で解放され、クラッシュもハングもしない。
    func testLargeStdinToNonReadingChildIsReleasedByTimeoutKill() {
        let bigInput = Data(repeating: UInt8(ascii: "a"), count: 128 * 1024)
        let start = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            stdin: bigInput,
            timeout: 0.2,
            drainGrace: 0.2
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 4.0)
    }

    /// 子自身は即 exit するが、子孫が stdin の read 端を継承して保持し続け、読まないケース。
    /// 同期 write だと「親は終了済み = timeout kill が発火しない」ため 64KB 超で永久ブロックし、
    /// ワーカースレッドがリークしていた経路（writability 駆動化の回帰検証）。
    /// 素の `sleep &` は POSIX 仕様でバックグラウンドジョブの stdin が /dev/null に
    /// 差し替わり再現しないため、`exec 3<&0` で fd を明示継承させる。
    func testStdinHeldByOrphanedDescendantDoesNotLeakWorkers() {
        let bigInput = Data(repeating: UInt8(ascii: "d"), count: 128 * 1024)
        for _ in 0..<20 {
            let start = Date()
            let result = ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "exec 3<&0; sleep 3 & exit 0"],
                stdin: bigInput,
                timeout: 5,
                drainGrace: 0.2
            )
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "stdin write がブロックしている")
        }

        // 直後の正常な呼び出しが速く正しく動けば、ワーカー非リークの証明になる
        let start = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf ok"],
            timeout: 5
        )
        XCTAssertEqual(result.stdoutString, "ok")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    /// 子が stdin を読まずに即 exit した後の stdin 書き込み（EPIPE/SIGPIPE）でも落ちない。
    func testStdinWriteAfterChildExitDoesNotCrash() {
        let bigInput = Data(repeating: UInt8(ascii: "b"), count: 128 * 1024)
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "exit 0"],
            stdin: bigInput,
            timeout: 5,
            drainGrace: 1
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    // MARK: - 正常系の回帰

    /// pipe バッファ（64KB）を大きく超える stdout も詰まらず全量読める。
    func testLargeStdoutIsFullyDrained() {
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=512 2>/dev/null"],
            timeout: 10
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 512 * 1024)
        XCTAssertFalse(result.stdoutTruncated)
    }

    /// stdin 供給 → stdout 読み取り（`git check-ignore --stdin` 相当の同時双方向）。
    func testStdinIsDeliveredAndEchoedBack() {
        let input = Data(repeating: UInt8(ascii: "c"), count: 100 * 1024)
        let result = ProcessRunner.run(
            executable: "/bin/cat",
            arguments: [],
            stdin: input,
            timeout: 10
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, input)
    }

    /// maxStdoutBytes 超過で terminate され、truncated フラグが立つ。
    func testMaxStdoutBytesTerminatesRunawayProcess() {
        let start = Date()
        let result = ProcessRunner.run(
            executable: "/usr/bin/yes",
            arguments: [],
            timeout: 10,
            maxStdoutBytes: 64 * 1024
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertGreaterThanOrEqual(result.stdout.count, 64 * 1024)
        XCTAssertLessThan(elapsed, 8.0)
    }

    /// timeout で SIGTERM が飛び、timedOut が立つ。
    func testTimeoutKillsLongRunningProcess() {
        let start = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.5,
            drainGrace: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 4.5)
    }

    /// stderr も独立に drain される。
    func testStderrIsDrained() {
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf out; printf err 1>&2"],
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "out")
        XCTAssertEqual(result.stderrString, "err")
    }

    /// 起動失敗（実行ファイルなし）は exitCode -1 で即座に返る。
    func testLaunchFailureReturnsImmediately() {
        let result = ProcessRunner.run(
            executable: "/nonexistent/binary",
            arguments: [],
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, -1)
    }

    // MARK: - Mach 例外ポート

    /// 子は親タスクの Mach 例外ポートを継承しない。
    /// 継承すると、子のクラッシュが親の例外ハンドラ（PolePole では libghostty 内の breakpad）に届き、
    /// breakpad の処理次第で本体ごと exit(1) する。ここでは返事をしない例外ポートを親に張っておき、
    /// 子が継承していればクラッシュ時に返事待ちで固まって timeout する、という形で検出する。
    ///
    /// 子には自前ビルドのバイナリを使う。Apple の platform binary（/usr/bin/perl 等）の例外は
    /// そもそも親の例外ポートに届かないため、継承していても検出できない（実害が出た Xcode 同梱の
    /// git は platform binary ではないので届く）。
    func testChildDoesNotInheritTaskExceptionPorts() throws {
        let crasher = try makeCrashingExecutable()
        let mask = exception_mask_t(EXC_MASK_BAD_ACCESS)
        let task = mach_task_self_

        // 既存の登録（Debug ホストなら breakpad）を退避して、テスト後に戻す
        var savedMasks = [exception_mask_t](repeating: 0, count: Int(EXC_TYPES_COUNT))
        var savedPorts = [mach_port_t](repeating: 0, count: Int(EXC_TYPES_COUNT))
        var savedBehaviors = [exception_behavior_t](repeating: 0, count: Int(EXC_TYPES_COUNT))
        var savedFlavors = [thread_state_flavor_t](repeating: 0, count: Int(EXC_TYPES_COUNT))
        var savedCount = mach_msg_type_number_t(EXC_TYPES_COUNT)
        XCTAssertEqual(
            task_get_exception_ports(task, mask, &savedMasks, &savedCount, &savedPorts, &savedBehaviors, &savedFlavors),
            KERN_SUCCESS
        )

        var port = mach_port_t(MACH_PORT_NULL)
        XCTAssertEqual(mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port), KERN_SUCCESS)
        XCTAssertEqual(mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)), KERN_SUCCESS)
        XCTAssertEqual(
            task_set_exception_ports(task, mask, port, exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE)),
            KERN_SUCCESS
        )
        defer {
            for i in 0..<Int(savedCount) {
                task_set_exception_ports(task, savedMasks[i], savedPorts[i], savedBehaviors[i], savedFlavors[i])
            }
            mach_port_mod_refs(task, port, MACH_PORT_RIGHT_RECEIVE, -1)
            mach_port_deallocate(task, port)
        }

        let start = Date()
        let result = ProcessRunner.run(
            executable: crasher,
            arguments: [],
            timeout: 3,
            drainGrace: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(result.timedOut, "子のクラッシュが親の例外ポートに届いている（elapsed=\(elapsed))")
        XCTAssertEqual(result.exitCode, SIGSEGV)
        XCTAssertLessThan(elapsed, 2.0)
    }

    /// 起動するとアドレス 8 を読んで SIGSEGV で落ちる実行ファイルをテンポラリに作る。
    private func makeCrashingExecutable() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("polepole-crasher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("crasher.c")
        try "int main(void) { volatile int *p = (int *)8; return *p; }\n".write(to: source, atomically: true, encoding: .utf8)
        let output = dir.appendingPathComponent("crasher").path
        let compile = ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["clang", "-o", output, source.path],
            timeout: 60
        )
        guard compile.exitCode == 0 else {
            throw XCTSkip("clang でクラッシュ用バイナリを作れない: \(compile.stderrString)")
        }
        return output
    }
}
