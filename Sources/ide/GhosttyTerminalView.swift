import AppKit
import SwiftUI
import GhosttyKit

// MARK: - SwiftUI ラッパー

struct GhosttyTerminalView: NSViewRepresentable {
    let pane: PaneState

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        let view = GhosttyTerminalNSView(frame: .zero)
        view.pane = pane
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {
        nsView.pane = pane
    }
}

// MARK: - NSView 実装
//
// 機能ごとの実装は今後 extension に切り出す予定:
//   - +Clipboard.swift   : Cmd+C/V / write/read_clipboard_cb
//   - +Mouse.swift       : mouseDown/Dragged/Up, scrollWheel
//   - +TextInput.swift   : NSTextInputClient（IME 対応）
//   - +Surface.swift     : surface lifecycle / sync size
// この本体ファイルにはライフサイクルと最小限のキー入力だけを残す方針。

final class GhosttyTerminalNSView: NSView {
    // extension からアクセスするので internal (private にしない)
    nonisolated(unsafe) var surface: ghostty_surface_t?
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0

    /// この NSView が属するペイン。Cmd+T/W や activePane 連動で参照する。
    weak var pane: PaneState?

    // IME（NSTextInputClient）の状態
    var markedText: NSMutableAttributedString = NSMutableAttributedString()
    var markedSelectedRange: NSRange = NSRange(location: 0, length: 0)
    /// keyDown 中のみ非 nil。IME confirmed text を一時的に貯める箱
    var keyTextAccumulator: [String]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        ensureTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        ensureTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        if let s = surface {
            GhosttyManager.shared.unregister(surface: s)
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
        // 自分の属するペインを active pane に昇格
        if let pane {
            WorkspaceModel.shared.setActive(pane)
        }
        if let s = surface {
            ghostty_surface_set_focus(s, true)
            // クリップボード等の "active surface" もこの NSView の surface に切替
            GhosttyManager.shared.register(surface: s)
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
        GhosttyManager.shared.register(surface: s)
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

    /// Cmd+V や Cmd+C などのメニューショートカットは AppKit が menu chain で先に消費する。
    /// Ghostty 側のキーバインドにマッチする場合はこちらで捕捉して surface に流す。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ide 側のショートカットを Ghostty より先に捕まえる。
        // 操作対象は WorkspaceModel.activePane（フォーカス中のペイン）。
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift),
           !event.modifierFlags.contains(.option),
           !event.modifierFlags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "t":
                WorkspaceModel.shared.activePane.addTab()
                return true
            case "w":
                WorkspaceModel.shared.activePane.closeActiveTab()
                return true
            default:
                break
            }
        }

        guard let s = surface else { return false }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepoint(from: event)

        var flags = ghostty_binding_flags_e(rawValue: 0)
        guard ghostty_surface_key_is_binding(s, keyEvent, &flags) else {
            return false
        }

        let chars = event.characters ?? ""
        return chars.withCString { ptr in
            keyEvent.text = chars.isEmpty ? nil : ptr
            return ghostty_surface_key(s, keyEvent)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { return super.keyDown(with: event) }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let markedBefore = markedText.length > 0

        // AppKit の IME パイプラインに通す。confirm された文字列は accumulator に流れる。
        keyTextAccumulator = []
        interpretKeyEvents([event])
        let accumulatedText = keyTextAccumulator ?? []
        keyTextAccumulator = nil

        // preedit の現状を Ghostty に同期
        syncPreedit()

        // IME が消費したケース: marked text が新たに発生・更新され、確定文字列が空なら surface に key を送らない
        if accumulatedText.isEmpty, markedText.length > 0 {
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = ghostty_input_mods_e(rawValue: 0)
        keyEvent.unshifted_codepoint = unshiftedCodepoint(from: event)
        keyEvent.composing = markedText.length > 0 || markedBefore

        if !accumulatedText.isEmpty {
            // IME 確定文字列を1つずつ送る
            keyEvent.composing = false
            for text in accumulatedText where !text.isEmpty {
                text.withCString { ptr in
                    keyEvent.text = ptr
                    _ = ghostty_surface_key(s, keyEvent)
                }
            }
            return
        }

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

// extension からも使うので fileprivate ではなく internal
func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
    let chars = event.charactersIgnoringModifiers ?? ""
    return chars.unicodeScalars.first?.value ?? 0
}

func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
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
