import AppKit
import GhosttyKit

extension GhosttyTerminalNSView {
    // MARK: - ボタン

    override func mouseDown(with event: NSEvent) {
        sendMouse(event, action: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(event, action: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouse(event, action: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouse(event, action: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouse(event, action: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouse(event, action: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    // MARK: - 移動

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    // MARK: - スクロール

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface else {
            super.scrollWheel(with: event)
            return
        }
        // macOS のスクロール方向は Ghostty の期待方向に揃える必要があるか要検証。
        // 現状は OS の値をそのまま渡し、自然スクロール ON/OFF はユーザーの OS 設定に従う。
        let mods: ghostty_input_scroll_mods_t = 0
        ghostty_surface_mouse_scroll(s, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    // MARK: - 共通ヘルパ

    private func sendMouse(
        _ event: NSEvent,
        action: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let s = surface else { return }
        sendMousePosition(event)
        _ = ghostty_surface_mouse_button(s, action, button, modsFromEvent(event))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let s = surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        // NSView は左下原点、Ghostty は左上原点なので Y 反転
        let y = bounds.height - local.y
        ghostty_surface_mouse_pos(s, local.x, y, modsFromEvent(event))
    }
}

// MARK: - Tracking Area

extension GhosttyTerminalNSView {
    func ensureTrackingArea() {
        for existing in trackingAreas {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeWhenFirstResponder, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
    }
}
