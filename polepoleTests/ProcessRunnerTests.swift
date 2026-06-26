import XCTest
@testable import polepole

final class ProcessRunnerTests: XCTestCase {
    func testRunReturnsWhenDescendantKeepsStdoutOpen() {
        let start = Date()
        let result = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf done; (sleep 10) &"],
            timeout: 5
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "done")
        XCTAssertLessThan(elapsed, 4.5)
    }
}
