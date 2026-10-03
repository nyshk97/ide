import XCTest
@testable import polepole

final class SpawnedChildTests: XCTestCase {
    /// 短命な子を並列に大量起動しても、exit を取りこぼさずに回収できる。
    /// exit 間際に登録した dispatch の process source は exit イベントが来ないことがあり、
    /// source だけに頼ると timeout まで待たされる（ProcessRunner が exitCode -1 を返す）。
    /// 負荷で遅れるだけなら落とさないよう、判定は「timeout 内に回収できたか」だけにする。
    func testShortLivedChildrenAreReapedPromptly() {
        let count = 1000
        let slow = ManagedAtomicCounter()
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            let child = SpawnedChild()
            guard (try? child.spawn(executable: "/usr/bin/true", arguments: [], cwd: nil, stdin: nil, stdout: nil, stderr: nil)) != nil else {
                slow.increment()
                return
            }
            if !child.waitForExit(timeout: 5) || child.terminationStatus != 0 {
                slow.increment()
            }
        }
        XCTAssertEqual(slow.value, 0, "\(slow.value)/\(count) 件の exit を timeout 内に回収できなかった")
    }
}

private final class ManagedAtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}
