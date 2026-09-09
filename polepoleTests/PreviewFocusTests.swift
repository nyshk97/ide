import AppKit
import SwiftUI
import XCTest
@testable import polepole

/// `PreviewFocus.isFirstResponderWithinPreview` の判定。
/// MRUKeyMonitor が検索バー用の Esc / Return / Cmd+G を握るのは、この述語が true のときだけ。
/// 「バーが見えているだけ」でターミナル作業中の Return / Esc を横取りしないための境界を固定する。
@MainActor
final class PreviewFocusTests: XCTestCase {
    private var window: NSWindow!
    private var preview: PreviewFocusHostingView<Text>!
    private var findField: NSTextField!
    private var terminal: NSView!

    override func setUp() {
        super.setUp()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // 既定の isReleasedWhenClosed=true だと close() と ARC の解放で二重解放になりクラッシュする
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root

        // プレビューペイン（NSHostingView）配下に検索バーの入力欄相当の NSTextField を置く
        preview = PreviewFocusHostingView(rootView: Text("preview"))
        preview.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        root.addSubview(preview)
        findField = NSTextField(frame: NSRect(x: 10, y: 10, width: 150, height: 22))
        preview.addSubview(findField)

        // ターミナル相当: プレビューの外にある first responder 可能な view
        terminal = FocusableView(frame: NSRect(x: 300, y: 0, width: 300, height: 400))
        root.addSubview(terminal)
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    func testFindFieldFocusedIsWithinPreview() {
        XCTAssertTrue(window.makeFirstResponder(findField))
        // 実アプリと同じく first responder は field editor (NSTextView) になる
        XCTAssertTrue(window.firstResponder is NSTextView, "first responder = \(String(describing: window.firstResponder))")
        XCTAssertTrue(PreviewFocus.isFirstResponderWithinPreview(in: window))
    }

    func testPreviewBodyFocusedIsWithinPreview() {
        XCTAssertTrue(window.makeFirstResponder(preview))
        XCTAssertTrue(PreviewFocus.isFirstResponderWithinPreview(in: window))
    }

    func testTerminalFocusedIsOutsidePreview() {
        // まず入力欄にフォーカスがある状態を作ってから、ターミナルに移す（バグの再現手順と同じ順序）
        XCTAssertTrue(window.makeFirstResponder(findField))
        XCTAssertTrue(PreviewFocus.isFirstResponderWithinPreview(in: window))
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertFalse(PreviewFocus.isFirstResponderWithinPreview(in: window))
    }

    func testNoViewResponderIsOutsidePreview() {
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(PreviewFocus.isFirstResponderWithinPreview(in: window))
        XCTAssertFalse(PreviewFocus.isFirstResponderWithinPreview(in: nil))
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
