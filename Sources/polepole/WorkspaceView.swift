import AppKit
import SwiftUI

/// 上小ターミナル + 下大ターミナルの 2 ペイン構成。
/// 初期比率は 3:7 で、ドラッグで自由にリサイズ可能。
/// SwiftUI の `VSplitView` は子ビューの idealHeight を尊重せず初期均等分割になるため、
/// `NSSplitViewController` を直接ラップして初回 layout で divider 位置を設定する。
struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        ZStack {
            SplitPane(initialTopRatio: 0.3, paneLayout: workspace.paneLayout) {
                TabsView(pane: workspace.topPane, workspace: workspace)
            } bottom: {
                TabsView(pane: workspace.bottomPane, workspace: workspace)
            }
            // Ghostty surface を抱える portal host を root ZStack の最上層に重ねる。
            // host の hitTest は subview のエリア外なら nil を返すので、空白部分のクリックは
            // 下の SwiftUI 階層 (タブバー / divider / ペイン背景) に通る (TerminalsHostView 参照)。
            TerminalsHostRepresentable(host: workspace.terminalsHost)
        }
    }
}

/// `TerminalsHostView` を SwiftUI ZStack に乗せるためのラッパ。
/// host 自体の frame は ZStack 全体に広げる。subview の frame は host が `setGeometry` で管理する。
private struct TerminalsHostRepresentable: NSViewRepresentable {
    let host: TerminalsHostView

    func makeNSView(context: Context) -> TerminalsHostView { host }
    func updateNSView(_ nsView: TerminalsHostView, context: Context) {}
}

/// 上下分割の SplitView。`initialTopRatio` で初期比率を指定し、
/// その後はユーザーがドラッグで自由にリサイズできる。
/// `paneLayout == .singleBottom` のときは上ペインを `isCollapsed = true` で畳む。
/// NSView は tree に残るため、上ペインのタブが持つ Ghostty surface は collapse 中も生存する。
private struct SplitPane<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let initialTopRatio: CGFloat
    let paneLayout: PaneLayout
    let top: () -> Top
    let bottom: () -> Bottom

    init(initialTopRatio: CGFloat, paneLayout: PaneLayout, @ViewBuilder top: @escaping () -> Top, @ViewBuilder bottom: @escaping () -> Bottom) {
        self.initialTopRatio = initialTopRatio
        self.paneLayout = paneLayout
        self.top = top
        self.bottom = bottom
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let svc = RatioSplitViewController()
        svc.initialTopRatio = initialTopRatio
        svc.splitView.isVertical = false
        svc.splitView.dividerStyle = .thin
        // 自前で初期比率を制御するので autosave は無効
        svc.splitView.autosaveName = nil

        let topVC = NSHostingController(rootView: top())
        let topItem = NSSplitViewItem(viewController: topVC)
        topItem.minimumThickness = 80
        topItem.isCollapsed = (paneLayout == .singleBottom)
        // 初期状態が collapsed なら、RatioSplitViewController の初回 setPosition で
        // divider 位置を 3:7 に戻されないよう「初期化済み」フラグを立てておく。
        if paneLayout == .singleBottom {
            svc.didSetInitial = true
        }
        svc.addSplitViewItem(topItem)

        let bottomVC = NSHostingController(rootView: bottom())
        let bottomItem = NSSplitViewItem(viewController: bottomVC)
        bottomItem.minimumThickness = 200
        svc.addSplitViewItem(bottomItem)

        context.coordinator.topVC = topVC
        context.coordinator.bottomVC = bottomVC
        context.coordinator.topItem = topItem
        return svc
    }

    func updateNSViewController(_ svc: NSSplitViewController, context: Context) {
        if let host = context.coordinator.topVC as? NSHostingController<Top> {
            host.rootView = top()
        }
        if let host = context.coordinator.bottomVC as? NSHostingController<Bottom> {
            host.rootView = bottom()
        }
        // paneLayout の変化を topItem.isCollapsed に反映する。animator を通すと滑らかに開閉する。
        if let topItem = context.coordinator.topItem {
            let shouldCollapse = (paneLayout == .singleBottom)
            if topItem.isCollapsed != shouldCollapse {
                topItem.animator().isCollapsed = shouldCollapse
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var topVC: NSViewController?
        weak var bottomVC: NSViewController?
        weak var topItem: NSSplitViewItem?
    }
}

/// 初回 layout で divider 位置を `initialTopRatio` に設定する SplitViewController。
/// `viewDidLayout` は中間サイズ (例: 500px) でも先に呼ばれるため、
/// bounds.height が前回と同値になった (= ウィンドウサイズが安定した) 段階で
/// 1 回だけ setPosition する。
private final class RatioSplitViewController: NSSplitViewController {
    var initialTopRatio: CGFloat = 0.3
    /// 初回 divider 設定が済んだか。`paneLayout == .singleBottom` で起動するときは
    /// 外部から true にして初回 setPosition を抑止する（collapsed 状態を上書きしないため）。
    var didSetInitial = false
    private var lastHeight: CGFloat = 0

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitial else { return }
        let h = splitView.bounds.height
        if h > 0 && h == lastHeight {
            splitView.setPosition(h * initialTopRatio, ofDividerAt: 0)
            didSetInitial = true
        }
        lastHeight = h
    }
}
