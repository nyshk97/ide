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

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY

        // ghostty_input_scroll_mods_t は src/input/mouse.zig の packed struct を int で表現したもの。
        //   bit 0      : precision（ピクセル単位の高精度デルタかどうか）
        //   bit 1..3   : momentum phase（慣性スクロールの段階）
        // bit 0 を立てないと Ghostty はデルタ値を「行数」として解釈するため、トラックパッドや
        // Magic Mouse のピクセル単位デルタ（数十px）がそのまま行数になりスクロールが暴走する。
        var mods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas {
            mods = 1
            // Ghostty 公式 macOS アプリと同じく 2x 倍率（体感上の調整値）。
            x *= 2
            y *= 2
        }

        // momentum phase を bit 1.. に詰める（Ghostty 公式アプリと同じ扱い）。
        let momentum: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        mods |= ghostty_input_scroll_mods_t(momentum.rawValue) << 1

        // スクロール方向は OS の値をそのまま渡し、自然スクロール ON/OFF はユーザーの OS 設定に従う。
        ghostty_surface_mouse_scroll(s, x, y, mods)
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
