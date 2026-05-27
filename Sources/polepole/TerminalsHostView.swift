import AppKit

/// 1 ワークスペース分の全 `GhosttyTerminalNSView` を 1 個の NSView 配下にまとめる "portal host"。
///
/// **設計動機**: libghostty は `ghostty_surface_new` 時に渡された NSView pointer と CAMetalLayer / display link を
/// 内部で握り続けるため、後から `addSubview` で superview を変えても Metal 描画は新階層に再束縛されない。
/// (試した記録は `docs/plans/2026-05-27-pane-layout-and-cross-pane-tabs.md` の Phase 3 ログ参照)
///
/// そのため、各 tab の `realNSView` は **この host に一度だけ attach** し、以降は reparent しない。
/// 代わりに「SwiftUI 側の `TerminalAnchorView` の frame」を host 座標に変換した値を `setGeometry` で受け取り、
/// `realNSView.frame` をその位置に追従させる (geometry reconcile)。
///
/// タブ移動 (ペイン跨ぎ) は `tabs` 配列上で TerminalTab を別 pane に移すだけで、`realNSView` の親は不変。
/// 次の layout pass で新 pane の anchor frame が伝わって `realNSView.frame` が追従して見た目が動く。
@MainActor
final class TerminalsHostView: NSView {
    /// 既に attach 済みの `realNSView` の集合。重複 `addSubview` を避ける逆引き。
    private var attached: Set<ObjectIdentifier> = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // host 自体は完全に透過。tab の NSView だけを subview として描画する。
        autoresizesSubviews = false
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// host 自体は透過のフィルム。subview (tab.realNSView) のエリア内ならその subview に hit を渡し、
    /// エリア外 (タブバー / ファイルツリー / サイドバー等) なら nil を返して下層の SwiftUI 階層に
    /// イベントを流す。
    ///
    /// **座標系の注意**: `NSView.hitTest(_:)` の point は **receiver の superview の座標系**で渡される
    /// (Apple docs)。`sub.hitTest(_:)` に渡すときは sub の superview = self 座標系の点を渡す必要がある
    /// ので、いったん self 座標に変換してから subview の判定に進む。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let pointInSelf = convert(point, from: superview)
        for sub in subviews.reversed() where !sub.isHidden {
            // sub.frame は sub.superview = self の座標系なので、self 座標の点と比較する
            if sub.frame.contains(pointInSelf) {
                return sub.hitTest(pointInSelf)
            }
        }
        return nil
    }

    /// 初回のみ `addSubview` する。2 回目以降は no-op (libghostty が surface 作成時の NSView pointer を握る前提)。
    /// `attach` 後の `realNSView` の親は固定。位置・可視は `setGeometry` で操作する。
    func attach(_ tabView: GhosttyTerminalNSView) {
        let key = ObjectIdentifier(tabView)
        guard !attached.contains(key) else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = true
        tabView.autoresizingMask = []  // host が手動で frame を更新するので autoresize させない
        addSubview(tabView)
        attached.insert(key)
    }

    /// `TerminalAnchorView` 経由で取得した anchor frame (host 座標系) を `tabView.frame` に反映する。
    /// `isActive == false` の tab はオフスクリーンに飛ばす (`isHidden = true` だと Metal renderer が一時停止する
    /// 可能性があるため、frame で逃がす方が安全)。active な tab は anchor frame で表示する。
    func setGeometry(for tabView: GhosttyTerminalNSView, frame: CGRect, isActive: Bool) {
        guard attached.contains(ObjectIdentifier(tabView)) else { return }
        if isActive {
            // 通常表示
            if tabView.isHidden { tabView.isHidden = false }
            if tabView.frame != frame {
                tabView.frame = frame
            }
        } else {
            // 非 active タブはオフスクリーンに退避 (ZStack の opacity 0 と同じ意図)。
            // 完全に消すと再表示時の描画起動コストがかかる + 上述の Metal 一時停止懸念があるため
            // 「画面外に置いて renderer は動かしておく」設計。
            let offscreen = CGRect(x: -10_000, y: -10_000, width: frame.width, height: frame.height)
            if tabView.frame != offscreen {
                tabView.frame = offscreen
            }
        }
    }

    /// タブを閉じるときに **必ず** 呼ぶ。host は subview を強参照するため、これを呼ばないと
    /// 閉じたタブの `realNSView` が画面に残り続け、描画残り・hit target 残留・firstResponder 残留・
    /// subview 蓄積につながる。さらに `TerminalTab` の deinit (= surface free) も host の強参照のせいで
    /// 遅延するため、`WorkspaceModel.closeTab` では `detach` 直後に `realNSView.releaseSurface()` を
    /// 即時呼んで PTY も即解放する。
    func detach(_ tabView: GhosttyTerminalNSView) {
        let key = ObjectIdentifier(tabView)
        guard attached.contains(key) else { return }
        tabView.removeFromSuperview()
        attached.remove(key)
    }
}
