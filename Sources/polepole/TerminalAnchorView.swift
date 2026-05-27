import AppKit
import SwiftUI

/// SwiftUI 階層に置く「軽量な穴」。実体は `TerminalsHostView` に attach 済みの
/// `tab.realNSView`。このビューは見た目を持たず、自身の frame 変化を `TerminalsHostView` に伝えて
/// realNSView の位置を追従させる。
///
/// 設計動機は `TerminalsHostView` の doc 参照 (libghostty が NSView pointer を握り続けるため
/// SwiftUI の view tree 変動から realNSView を保護する必要がある)。
struct TerminalAnchorView: NSViewRepresentable {
    let tab: TerminalTab
    let pane: PaneState
    @ObservedObject var workspace: WorkspaceModel
    let isActive: Bool

    func makeNSView(context: Context) -> AnchorNSView {
        let view = AnchorNSView()
        view.host = workspace.terminalsHost
        // realNSView.pane を初期化 (`becomeFirstResponder` が pane.setActive を呼ぶので必須)。
        tab.realNSView.pane = pane
        view.onLayout = { [weak host = workspace.terminalsHost, weak realView = tab.realNSView] anchorFrameInHost in
            guard let host, let realView else { return }
            // host への初回 attach を保証 (重複は host 側で skip)
            host.attach(realView)
            host.setGeometry(for: realView, frame: anchorFrameInHost, isActive: context.coordinator.isActive)
        }
        context.coordinator.isActive = isActive
        return view
    }

    func updateNSView(_ nsView: AnchorNSView, context: Context) {
        // pane 参照を毎回張り替える。
        // ペイン跨ぎ移動 (Phase 3) で同じ tab が反対側ペインの ForEach に出現したとき、
        // SwiftUI が `.id(tab.id)` で identity を引き継ぐ場合 updateNSView だけ呼ばれる。
        // pane を更新しないと、becomeFirstResponder が古い pane を setActive してしまい、
        // クリック / Cmd+Opt+↑↓ でフォーカスが移らない症状になる。
        tab.realNSView.pane = pane

        let activeChanged = context.coordinator.isActive != isActive
        context.coordinator.isActive = isActive
        if activeChanged {
            // active 切替時は次の layout を待たずに即時反映 (タブ切替後すぐに新タブが見える状態を作る)
            nsView.notifyHostNow()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var isActive: Bool = false
    }
}

/// `TerminalAnchorView` の実体 NSView。`viewDidMoveToWindow` / `setFrameOrigin` / `setFrameSize` /
/// `viewDidEndLiveResize` で host への frame 通知をトリガする。frame は host 座標系に変換して渡す。
@MainActor
final class AnchorNSView: NSView {
    /// host への weak 参照。座標変換ターゲットとして使う。
    weak var host: TerminalsHostView?
    /// host に渡す callback。引数は host 座標系での anchor frame。
    var onLayout: ((CGRect) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false  // 自身は描画しない (透明な anchor)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyHostNow()
    }

    /// 同じ window 内で SwiftUI / AppKit が anchor view を別 superview に reparent した場合、
    /// `viewDidMoveToWindow` は発火しないことがある。`setFrameOrigin/Size` で救われるケースが多いが、
    /// 新旧 superview で anchor の相対 frame がたまたま同じだと stale geometry になり得るので、
    /// superview 変動でも host への通知を発火させておく。
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        notifyHostNow()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        notifyHostNow()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        notifyHostNow()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        notifyHostNow()
    }

    /// 強制的に host に現在の anchor frame を通知する。
    /// `convert(_:to:)` は両 view が isFlipped で違っても自動補正してくれる。
    /// host が ZStack 経由で配置されていて contentView と座標が一致しないケースに対応するため、
    /// 直接 host 座標に変換する (contentView を経由しない)。
    func notifyHostNow() {
        guard let onLayout, window != nil, let host else { return }
        let frameInHost = self.convert(self.bounds, to: host)
        onLayout(frameInHost)
    }
}
