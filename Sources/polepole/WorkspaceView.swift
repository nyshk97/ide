import AppKit
import SwiftUI

/// ペイン構成に応じてターミナルエリアを描画するビュー。
/// paneLayout に応じて 1/2/4 ペインを切り替える。
struct WorkspaceView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        ZStack {
            if workspace.paneLayout == .splitFour {
                fourPaneLayout
            } else {
                twoPaneLayout
            }
            // Ghostty surface を抱える portal host を root ZStack の最上層に重ねる。
            // host の hitTest は subview のエリア外なら nil を返すので、空白部分のクリックは
            // 下の SwiftUI 階層 (タブバー / divider / ペイン背景) に通る (TerminalsHostView 参照)。
            TerminalsHostRepresentable(host: workspace.terminalsHost)
        }
    }

    /// singleBottom / split / splitHorizontal の 3 ケース。
    /// `.id(isVertical)` で方向変更時に NSSplitViewController を再生成する。
    private var twoPaneLayout: some View {
        let isVertical = workspace.paneLayout == .splitHorizontal
        let isCollapsed = workspace.paneLayout == .singleBottom
        return SplitPane(
            initialRatio: isVertical ? 0.5 : 0.3,
            isVertical: isVertical,
            isCollapsed: isCollapsed
        ) {
            TabsView(pane: workspace.topPane, workspace: workspace)
        } secondary: {
            TabsView(pane: workspace.bottomPane, workspace: workspace)
        }
        .id(isVertical)
    }

    /// splitFour (2×2 グリッド) レイアウト。
    /// SplitPane のネスト（NSViewControllerRepresentable のネスト）はクラッシュするため、
    /// FourPaneSplit を使って純粋な AppKit で 3 つの NSSplitView を直接組み上げる。
    private var fourPaneLayout: some View {
        FourPaneSplit {
            TabsView(pane: workspace.topPane, workspace: workspace)
        } bottomLeft: {
            TabsView(pane: workspace.bottomPane, workspace: workspace)
        } topRight: {
            TabsView(pane: workspace.topRightPane, workspace: workspace)
        } bottomRight: {
            TabsView(pane: workspace.bottomRightPane, workspace: workspace)
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

/// 汎用 2 ペイン SplitView。`initialRatio` で初期比率を指定し、その後はユーザーがドラッグで
/// 自由にリサイズできる。`isVertical=false` は上下分割（水平 divider）、
/// `isVertical=true` は左右分割（垂直 divider）。
/// `isCollapsed=true` のとき primary（上または左）を折り畳む。
private struct SplitPane<Primary: View, Secondary: View>: NSViewControllerRepresentable {
    let initialRatio: CGFloat
    let isVertical: Bool
    let isCollapsed: Bool
    let primary: () -> Primary
    let secondary: () -> Secondary

    init(
        initialRatio: CGFloat,
        isVertical: Bool,
        isCollapsed: Bool,
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder secondary: @escaping () -> Secondary
    ) {
        self.initialRatio = initialRatio
        self.isVertical = isVertical
        self.isCollapsed = isCollapsed
        self.primary = primary
        self.secondary = secondary
    }

    func makeNSViewController(context: Context) -> RatioSplitViewController {
        let svc = RatioSplitViewController()
        svc.initialRatio = initialRatio
        svc.isVertical = isVertical
        svc.splitView.isVertical = isVertical
        svc.splitView.autosaveName = nil

        let primaryVC = NSHostingController(rootView: primary())
        let primaryItem = NSSplitViewItem(viewController: primaryVC)
        primaryItem.minimumThickness = isVertical ? 120 : 80
        primaryItem.isCollapsed = isCollapsed
        // 初期状態が collapsed なら、初回 setPosition で上書きしないよう済みフラグを立てる
        if isCollapsed { svc.didSetInitial = true }
        svc.addSplitViewItem(primaryItem)

        let secondaryVC = NSHostingController(rootView: secondary())
        let secondaryItem = NSSplitViewItem(viewController: secondaryVC)
        secondaryItem.minimumThickness = isVertical ? 120 : 200
        svc.addSplitViewItem(secondaryItem)

        context.coordinator.primaryVC = primaryVC
        context.coordinator.secondaryVC = secondaryVC
        context.coordinator.primaryItem = primaryItem
        return svc
    }

    func updateNSViewController(_ svc: RatioSplitViewController, context: Context) {
        if let host = context.coordinator.primaryVC as? NSHostingController<Primary> {
            host.rootView = primary()
        }
        if let host = context.coordinator.secondaryVC as? NSHostingController<Secondary> {
            host.rootView = secondary()
        }
        if let item = context.coordinator.primaryItem {
            if item.isCollapsed != isCollapsed {
                item.animator().isCollapsed = isCollapsed
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var primaryVC: NSViewController?
        weak var secondaryVC: NSViewController?
        weak var primaryItem: NSSplitViewItem?
    }
}

/// 初回 layout で divider 位置を `initialRatio` に設定する SplitViewController。
/// `viewDidLayout` は中間サイズでも先に呼ばれるため、
/// bounds のサイズが安定した（前回と同値になった）段階で 1 回だけ setPosition する。
///
/// `loadView()` で `splitView` を `WideHandleSplitView` に差し替える。
private final class RatioSplitViewController: NSSplitViewController {
    var initialRatio: CGFloat = 0.3
    var isVertical: Bool = false
    var didSetInitial = false
    private var lastDimension: CGFloat = 0

    override func loadView() {
        let custom = WideHandleSplitView()
        custom.identifier = NSUserInterfaceItemIdentifier("NSSplitViewControllerSplitView")
        custom.dividerStyle = .thin
        custom.isVertical = isVertical  // super.loadView() より前に設定しないと上書きされる
        self.splitView = custom
        super.loadView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitial else { return }
        let dim = isVertical ? splitView.bounds.width : splitView.bounds.height
        if dim > 0 && dim == lastDimension {
            splitView.setPosition(dim * initialRatio, ofDividerAt: 0)
            didSetInitial = true
        }
        lastDimension = dim
    }
}

/// 2×2 グリッドレイアウト用 NSViewControllerRepresentable。
/// NSSplitPane（NSViewControllerRepresentable）をネストすると SwiftUI の VC 親子ツリーが
/// 壊れてクラッシュするため、外側・左列・右列の 3 つの WideHandleSplitView を直接 AppKit で
/// 組み上げる単一 VC に実装する。
private struct FourPaneSplit<TL: View, BL: View, TR: View, BR: View>: NSViewControllerRepresentable {
    let topLeft: () -> TL
    let bottomLeft: () -> BL
    let topRight: () -> TR
    let bottomRight: () -> BR

    init(
        @ViewBuilder topLeft: @escaping () -> TL,
        @ViewBuilder bottomLeft: @escaping () -> BL,
        @ViewBuilder topRight: @escaping () -> TR,
        @ViewBuilder bottomRight: @escaping () -> BR
    ) {
        self.topLeft = topLeft
        self.bottomLeft = bottomLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
    }

    func makeNSViewController(context: Context) -> FourPaneViewController {
        let svc = FourPaneViewController()
        let tlVC = NSHostingController(rootView: topLeft())
        let blVC = NSHostingController(rootView: bottomLeft())
        let trVC = NSHostingController(rootView: topRight())
        let brVC = NSHostingController(rootView: bottomRight())
        svc.setupPanes(topLeft: tlVC, bottomLeft: blVC, topRight: trVC, bottomRight: brVC)
        context.coordinator.update(tlVC: tlVC, blVC: blVC, trVC: trVC, brVC: brVC)
        return svc
    }

    func updateNSViewController(_ svc: FourPaneViewController, context: Context) {
        let c = context.coordinator
        (c.tlVC as? NSHostingController<TL>)?.rootView = topLeft()
        (c.blVC as? NSHostingController<BL>)?.rootView = bottomLeft()
        (c.trVC as? NSHostingController<TR>)?.rootView = topRight()
        (c.brVC as? NSHostingController<BR>)?.rootView = bottomRight()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var tlVC: NSViewController?
        var blVC: NSViewController?
        var trVC: NSViewController?
        var brVC: NSViewController?
        func update(tlVC: NSViewController, blVC: NSViewController, trVC: NSViewController, brVC: NSViewController) {
            self.tlVC = tlVC; self.blVC = blVC; self.trVC = trVC; self.brVC = brVC
        }
    }
}

/// 2×2 レイアウトを管理する ViewController。
/// 3 つの WideHandleSplitView（外側 left/right、左列 top/bottom、右列 top/bottom）を直接管理する。
private final class FourPaneViewController: NSViewController {
    private var outerSplit: WideHandleSplitView!
    private var leftSplit: WideHandleSplitView!
    private var rightSplit: WideHandleSplitView!
    private var didSetInitial = false
    private var lastSize: CGSize = .zero

    func setupPanes(
        topLeft: NSViewController,
        bottomLeft: NSViewController,
        topRight: NSViewController,
        bottomRight: NSViewController
    ) {
        addChild(topLeft)
        addChild(bottomLeft)
        addChild(topRight)
        addChild(bottomRight)

        leftSplit = WideHandleSplitView()
        leftSplit.isVertical = false
        leftSplit.dividerStyle = .thin
        leftSplit.addArrangedSubview(topLeft.view)
        leftSplit.addArrangedSubview(bottomLeft.view)

        rightSplit = WideHandleSplitView()
        rightSplit.isVertical = false
        rightSplit.dividerStyle = .thin
        rightSplit.addArrangedSubview(topRight.view)
        rightSplit.addArrangedSubview(bottomRight.view)

        outerSplit = WideHandleSplitView()
        outerSplit.isVertical = true
        outerSplit.dividerStyle = .thin
        outerSplit.addArrangedSubview(leftSplit)
        outerSplit.addArrangedSubview(rightSplit)
    }

    override func loadView() {
        view = outerSplit ?? NSView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitial else { return }
        let sz = view.bounds.size
        guard sz.width > 0, sz.height > 0, sz == lastSize else { lastSize = sz; return }
        outerSplit.setPosition(sz.width * 0.5, ofDividerAt: 0)
        leftSplit.setPosition(sz.height * 0.5, ofDividerAt: 0)
        rightSplit.setPosition(sz.height * 0.5, ofDividerAt: 0)
        didSetInitial = true
    }
}

/// divider の drag ヒット領域を広げる NSSplitView。
///
/// `dividerStyle = .thin` のデフォルトでは divider hot region が 1px しかなく、ドラッグで
/// 掴むのが難しい。`dividerThickness` を 11px に広げて掴みやすくしつつ、`drawDivider(in:)` で
/// 中央 1px だけ separator 色を塗るので見た目は従来の細い線のまま。
///
/// **既知の制約**: ホバー時の resize cursor は出せていない。原因と試行錯誤の全記録は
/// [docs/DEV.md](../../docs/DEV.md) の「上下 divider にホバーしても resize cursor が出ない」を参照。
private final class WideHandleSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 11 }

    override func drawDivider(in rect: NSRect) {
        // 中央 1px だけ separatorColor で塗る。視覚的には従来の thin divider と同じ。
        NSColor.separatorColor.setFill()
        let line: NSRect
        if isVertical {
            line = NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height)
        } else {
            line = NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)
        }
        line.fill()
    }
}
