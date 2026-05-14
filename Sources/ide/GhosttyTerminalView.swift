import AppKit
import SwiftUI
import GhosttyKit

// MARK: - SwiftUI ラッパー

struct GhosttyTerminalView: NSViewRepresentable {
    let pane: PaneState
    let tab: TerminalTab

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        let view = GhosttyTerminalNSView(frame: .zero)
        view.pane = pane
        view.tab = tab
        return view
    }

    func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {
        nsView.pane = pane
        nsView.tab = tab
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

    /// この NSView が紐づく TerminalTab。surface 作成時に GhosttyManager に登録して逆引きに使う。
    weak var tab: TerminalTab?

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
        // 端末にフォーカスが移ったらファイルツリーのフォーカス状態を落とす（Cmd+R 誤発火防止）。
        // SwiftUI の @FocusState は AppKit の firstResponder 移動を検知しないことがあるため明示的に。
        ProjectsModel.shared.fileTreeFocused = false
        // 自分の属するペインを active pane に昇格＆そのタブの未読をクリアする。
        // ただし、ユーザー操作（クリック・キー）起因のときのみ。NSWindow の自動 initialFirstResponder
        // 等のレイアウト起因では、WorkspaceModel.init の activePane=bottomPane を上書きしてしまう上、
        // バックグラウンド workspace のタブに立っている未読通知まで消してしまうため除外する。
        if let pane, isUserDrivenFirstResponderChange() {
            ProjectsModel.shared.activeWorkspace?.setActive(pane)
            tab?.hasUnreadNotification = false
            ProjectsModel.shared.refreshUnreadProjects()
        }
        if let s = surface, let tab {
            ghostty_surface_set_focus(s, true)
            GhosttyManager.shared.register(surface: s, tab: tab)
        }
        return ok
    }

    private func isUserDrivenFirstResponderChange() -> Bool {
        guard let e = NSApp.currentEvent else { return false }
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .keyUp:
            return true
        default:
            return false
        }
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
            Logger.shared.debug("[surface] GhosttyManager.app is nil")
            return
        }
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 1)
        // font_size = 0 で config の値を使う想定（cmux 同様）
        // command/initial_input は nil（$SHELL -l を使う）

        // working_directory はプロジェクトルートを渡す。tab.cwd が nil なら ghostty 既定（HOME）。
        // C 文字列は createSurface のスコープ内で生かしておく必要があるので、ここで保持。
        let cwdString = tab?.cwd?.path
        if let cwdString {
            cwdString.withCString { ptr in
                cfg.working_directory = ptr
                guard let s = ghostty_surface_new(app, &cfg) else {
                    Logger.shared.debug("[surface] ghostty_surface_new returned nil")
                    return
                }
                attachSurface(s, cfg: cfg)
            }
        } else {
            guard let s = ghostty_surface_new(app, &cfg) else {
                Logger.shared.debug("[surface] ghostty_surface_new returned nil")
                return
            }
            attachSurface(s, cfg: cfg)
        }
    }

    private func attachSurface(_ s: ghostty_surface_t, cfg: ghostty_surface_config_s) {
        surface = s
        if let tab {
            GhosttyManager.shared.register(surface: s, tab: tab)
        }
        let scale = window?.backingScaleFactor ?? 1
        ghostty_surface_set_content_scale(s, scale, scale)
        if let displayID = window?.screen?.displayID {
            ghostty_surface_set_display_id(s, displayID)
        }
        syncSize()
        let cwdLog = tab?.cwd?.path ?? "(default)"
        Logger.shared.debug("[surface] new ok cwd=\(cwdLog)")
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
        // モーダル overlay（Cmd+P 検索 / Cmd+Shift+F 全文検索 / diff / MRU）表示中は
        // Ghostty で Cmd+V や Cmd+A 等を握らない。performKeyEquivalent は responder chain
        // ではなく view 階層を深さ優先で走るため、ここで握ると overlay の TextField が
        // first responder でもターミナル側に paste が流れてしまう。false を返して
        // AppKit 標準の Edit メニュー → 検索窓の field editor に paste: を届ける。
        let model = ProjectsModel.shared
        if model.quickSearchVisible || model.fullSearchVisible
            || model.diffOverlayVisible || model.mruOverlay != nil {
            return false
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        // macOS 標準のアプリケーションメニュー系ショートカット（Cmd+Q/Cmd+H/Cmd+M、
        // Cmd+Opt+H）は Ghostty に渡さずメニューチェーンに通す。Ghostty 内部で
        // Cmd+Q を quit バインドとして握ってしまい、アプリ側の terminate に届かない
        // 現象の対策。
        if mods == .command, chars == "q" || chars == "h" || chars == "m" {
            return false
        }
        if mods == [.command, .option], chars == "h" {
            return false
        }

        // ide 側のショートカットを Ghostty より先に捕まえる。
        // 操作対象は WorkspaceModel.activePane（フォーカス中のペイン）。
        if mods == .command {
            switch chars {
            case "t":
                ProjectsModel.shared.activeWorkspace?.activePane.addTab()
                return true
            case "w":
                ProjectsModel.shared.activeWorkspace?.activePane.closeActiveTab()
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

        let textChars = event.characters ?? ""
        return textChars.withCString { ptr in
            keyEvent.text = textChars.isEmpty ? nil : ptr
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

        // Ctrl のみ修飾のときは text に "\u{06}" のような制御文字を渡すと、
        // Ghostty が CSI-u 形式（"\e[102;5u"）でエンコードしてしまう。zsh-autosuggestions の
        // `bindkey '^F' autosuggest-accept` を効かせるため、unshifted 文字（"f"）を渡して
        // Ghostty に legacy ASCII (^F=0x06) でエンコードさせる。
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars: String = {
            let raw: String
            if mods.contains(.control), !mods.contains(.command), !mods.contains(.option) {
                raw = event.charactersIgnoringModifiers ?? event.characters ?? ""
            } else {
                raw = event.characters ?? ""
            }
            // 矢印キーや F キーは event.characters が NSUpArrowFunctionKey 等の
            // Private Use Area (U+F700〜U+F8FF) を返す。これを text として Ghostty に
            // 渡すと keycode の ESC シーケンス encode が抑止されて PUA がそのまま
            // PTY に流れる。keycode だけ送って Ghostty 内部で encode させる。
            if raw.count == 1, let scalar = raw.unicodeScalars.first,
               scalar.value >= 0xF700, scalar.value <= 0xF8FF {
                return ""
            }
            return raw
        }()
        if !chars.isEmpty, !mods.contains(.command) {
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
    guard let value = chars.unicodeScalars.first?.value else { return 0 }
    // 矢印キー等の Private Use Area (U+F700〜U+F8FF) は unshifted codepoint としても
    // 渡さない（Ghostty 側の encoding がおかしくなる）。
    if value >= 0xF700, value <= 0xF8FF { return 0 }
    return value
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
