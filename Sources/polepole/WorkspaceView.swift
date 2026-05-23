import AppKit
import SwiftUI

/// 上小ターミナル + 下大ターミナルの 2 ペイン構成。
/// 初期比率は 3:7 で、ドラッグで自由にリサイズ可能。
/// SwiftUI の `VSplitView` は子ビューの idealHeight を尊重せず初期均等分割になるため、
/// `NSSplitViewController` を直接ラップして初回 layout で divider 位置を設定する。
struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        SplitPane(initialTopRatio: 0.3) {
            TabsView(pane: workspace.topPane, workspace: workspace)
        } bottom: {
            TabsView(pane: workspace.bottomPane, workspace: workspace)
        }
    }
}

/// 上下分割の SplitView。`initialTopRatio` で初期比率を指定し、
/// その後はユーザーがドラッグで自由にリサイズできる。
private struct SplitPane<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let initialTopRatio: CGFloat
    let top: () -> Top
    let bottom: () -> Bottom

    init(initialTopRatio: CGFloat, @ViewBuilder top: @escaping () -> Top, @ViewBuilder bottom: @escaping () -> Bottom) {
        self.initialTopRatio = initialTopRatio
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
        svc.addSplitViewItem(topItem)

        let bottomVC = NSHostingController(rootView: bottom())
        let bottomItem = NSSplitViewItem(viewController: bottomVC)
        bottomItem.minimumThickness = 200
        svc.addSplitViewItem(bottomItem)

        context.coordinator.topVC = topVC
        context.coordinator.bottomVC = bottomVC
        return svc
    }

    func updateNSViewController(_ svc: NSSplitViewController, context: Context) {
        if let host = context.coordinator.topVC as? NSHostingController<Top> {
            host.rootView = top()
        }
        if let host = context.coordinator.bottomVC as? NSHostingController<Bottom> {
            host.rootView = bottom()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var topVC: NSViewController?
        weak var bottomVC: NSViewController?
    }
}

/// 初回 layout で divider 位置を `initialTopRatio` に設定する SplitViewController。
/// `viewDidLayout` は中間サイズ (例: 500px) でも先に呼ばれるため、
/// bounds.height が前回と同値になった (= ウィンドウサイズが安定した) 段階で
/// 1 回だけ setPosition する。
private final class RatioSplitViewController: NSSplitViewController {
    var initialTopRatio: CGFloat = 0.3
    private var didSetInitial = false
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
