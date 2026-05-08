import AppKit
import SwiftUI
import GhosttyKit

// MARK: - SwiftUI ラッパー

struct GhosttyTerminalView: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        GhosttyTerminalNSView(frame: .zero)
    }

    func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {}
}

// MARK: - NSView 実装

final class GhosttyTerminalNSView: NSView {
    nonisolated(unsafe) private var surface: ghostty_surface_t?
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        if let s = surface {
            ghostty_surface_free(s)
        }
    }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        if window != nil, surface == nil {
            createSurface()
            // SwiftUI の WindowGroup 配下では自動で first responder にならないので明示
            window?.makeFirstResponder(self)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 1
        layer?.contentsScale = scale
        if let s = surface {
            ghostty_surface_set_content_scale(s, scale, scale)
        }
        syncSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSize()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let s = surface {
            ghostty_surface_set_focus(s, true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let s = surface {
            ghostty_surface_set_focus(s, false)
        }
        return ok
    }

    // MARK: - Surface 作成・サイズ同期

    private func createSurface() {
        guard let app = GhosttyManager.shared.app else {
            PocLog.write("[surface] GhosttyManager.app is nil")
            return
        }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 1)
        // font_size = 0 で config の値を使う想定（cmux 同様）
        // command/working_directory/initial_input は nil（$SHELL -l + HOME を使う）

        guard let s = ghostty_surface_new(app, &cfg) else {
            PocLog.write("[surface] ghostty_surface_new returned nil")
            return
        }
        surface = s
        let scale = window?.backingScaleFactor ?? 1
        ghostty_surface_set_content_scale(s, scale, scale)
        if let displayID = window?.screen?.displayID {
            ghostty_surface_set_display_id(s, displayID)
        }
        syncSize()
        PocLog.write("[surface] new ok")
    }

    private func syncSize() {
        guard let s = surface else { return }
        let backing = convertToBacking(NSRect(origin: .zero, size: bounds.size)).size
        let wpx = UInt32(max(0, backing.width.rounded()))
        let hpx = UInt32(max(0, backing.height.rounded()))
        guard wpx > 0, hpx > 0 else { return }
        guard wpx != lastPixelWidth || hpx != lastPixelHeight else { return }
        lastPixelWidth = wpx
        lastPixelHeight = hpx
        ghostty_surface_set_size(s, wpx, hpx)
        if let m = layer as? CAMetalLayer {
            m.drawableSize = CGSize(width: Double(wpx), height: Double(hpx))
        }
    }

    // MARK: - キー入力（PoC は最小限。IME・修飾キー特殊処理なし）

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { return super.keyDown(with: event) }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0

        let chars = event.characters ?? ""
        if !chars.isEmpty, !event.modifierFlags.contains(.command) {
            chars.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(s, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(s, keyEvent)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let s = surface else { return super.keyUp(with: event) }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = 0
        keyEvent.text = nil
        _ = ghostty_surface_key(s, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        // 修飾キー単独の変化は今は無視（cmux でも分岐が複雑なので PoC では割愛）
        super.flagsChanged(with: event)
    }
}

// MARK: - ヘルパ

private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    let f = event.modifierFlags
    if f.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if f.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if f.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if f.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if f.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: raw)
}

private extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
