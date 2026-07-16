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
}
