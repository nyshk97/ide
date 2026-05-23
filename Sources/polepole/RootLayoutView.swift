import AppKit
import SwiftUI

/// IDE 全体のルートレイアウト（3 カラム）。
/// 左: プロジェクト一覧サイドバー / 中央: ファイルツリー or プレビュー / 右: ターミナル。
/// 初期比率はサイドバー幅確定後の残りを center:right = 2:3、ドラッグした幅は
/// `NSSplitView.autosaveName` で永続化して次回起動時に復元する。
struct RootLayoutView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    var body: some View {
        // SwiftUI の HSplitView は autosaveName を露出せず idealWidth も hint 程度にしか
        // 効かないため、WorkspaceView と同じく NSSplitViewController を直接ラップする。
        ThreeColumnSplit(
            autosaveName: "ide.rootSplit",
            initialCenterRatio: 0.4,
            leftMin: 120,
            leftInitial: 140,
            leftMax: 180,
            centerMin: 240,
            rightMin: 400
        ) {
            LeftSidebarView()
        } center: {
            CenterPaneView()
        } right: {
            rightArea
        }
        .overlay(alignment: .center) {
            if let state = projects.mruOverlay {
                MRUOverlayView(state: state)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if projects.quickSearchVisible, let active = projects.activeProject {
                QuickSearchView(
                    index: projects.fileIndex(for: active),
                    query: Binding(
                        get: { projects.quickSearchQuery },
                        set: { projects.quickSearchQuery = $0 }
                    ),
                    selection: Binding(
                        get: { projects.quickSearchSelection },
                        set: { projects.quickSearchSelection = $0 }
                    ),
                    onSelect: { projects.quickSearchSelect($0) },
                    onCancel: { projects.closeQuickSearch() }
                )
                .padding(.top, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if projects.fullSearchVisible {
                FullSearchView(
                    query: Binding(
                        get: { projects.fullSearchQuery },
                        set: { projects.fullSearchQuery = $0 }
                    ),
                    hits: Binding(
                        get: { projects.fullSearchHits },
                        set: { projects.fullSearchHits = $0 }
                    ),
                    selection: Binding(
                        get: { projects.fullSearchSelection },
                        set: { projects.fullSearchSelection = $0 }
                    ),
                    isSearching: Binding(
                        get: { projects.fullSearchInProgress },
                        set: { projects.fullSearchInProgress = $0 }
                    ),
                    onSubmit: { projects.runFullSearch() },
                    onSelect: { projects.fullSearchSelect($0) },
                    onCancel: { projects.closeFullSearch() }
                )
                .padding(.top, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if projects.diffOverlayVisible, let active = projects.activeProject {
                DiffOverlayView(
                    viewModel: projects.diffViewModel,
                    repoPath: active.path,
                    projectName: active.displayName,
                    onClose: { projects.closeDiffOverlay() }
                )
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            ToastStackView()
        }
    }

    /// 右ペイン: 一度開いた project の WorkspaceView を ZStack で重ねて opacity 切替。
    /// shell プロセスは active を切り替えても破棄されない（close されるまで生きる）。
    @ViewBuilder
    private var rightArea: some View {
        if projects.workspaces.isEmpty || projects.activeProject == nil {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Open a project to launch the terminal")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ZStack {
                ForEach(loadedProjects) { project in
                    WorkspaceView(workspace: projects.workspace(for: project))
                        .opacity(project.id == projects.activeProject?.id ? 1 : 0)
                        .allowsHitTesting(project.id == projects.activeProject?.id)
                }
            }
        }
    }

    /// workspaces dictionary に存在する（=一度でも開いた）プロジェクトのみ列挙。
    /// 順序は allOrdered 準拠で安定させる。
    private var loadedProjects: [Project] {
        projects.allOrdered.filter { projects.workspaces[$0.id] != nil }
    }
}

/// 3 カラム横分割。autosaveName で divider 位置を AppKit に永続化させ、
/// 初回起動 (保存値なし) のときだけ initialCenterRatio で center:right を割り当てる。
private struct ThreeColumnSplit<L: View, C: View, R: View>: NSViewControllerRepresentable {
    let autosaveName: String
    let initialCenterRatio: CGFloat  // 左 sidebar を除いた残り幅に対する center の割合
    let leftMin: CGFloat
    let leftInitial: CGFloat
    let leftMax: CGFloat
    let centerMin: CGFloat
    let rightMin: CGFloat
    let left: () -> L
    let center: () -> C
    let right: () -> R

    init(
        autosaveName: String,
        initialCenterRatio: CGFloat,
        leftMin: CGFloat, leftInitial: CGFloat, leftMax: CGFloat,
        centerMin: CGFloat,
        rightMin: CGFloat,
        @ViewBuilder left: @escaping () -> L,
        @ViewBuilder center: @escaping () -> C,
        @ViewBuilder right: @escaping () -> R
    ) {
        self.autosaveName = autosaveName
        self.initialCenterRatio = initialCenterRatio
        self.leftMin = leftMin
        self.leftInitial = leftInitial
        self.leftMax = leftMax
        self.centerMin = centerMin
        self.rightMin = rightMin
        self.left = left
        self.center = center
        self.right = right
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let svc = ThreeColumnSplitController()
        svc.initialCenterRatio = initialCenterRatio
        svc.leftInitial = leftInitial
        // splitView を差し替えて divider 上の mouseDown を捕捉する。
        let custom = DragDetectingSplitView()
        custom.onDividerDragStart = { [weak svc] in svc?.userHasDragged = true }
        svc.splitView = custom
        svc.splitView.isVertical = true
        svc.splitView.dividerStyle = .thin
        // autosave データの有無を「設定前に」確認する。
        // AppKit は autosaveName をセットした時点で `NSSplitView Subview Frames <name>`
        // を読みに行くので、ここで先回りして保存有無を見ておかないと判定できない。
        let key = "NSSplitView Subview Frames \(autosaveName)"
        svc.hasAutosavedFrames = UserDefaults.standard.object(forKey: key) != nil
        svc.splitView.autosaveName = NSSplitView.AutosaveName(autosaveName)

        let leftVC = NSHostingController(rootView: left())
        let leftItem = NSSplitViewItem(viewController: leftVC)
        leftItem.minimumThickness = leftMin
        leftItem.maximumThickness = leftMax
        leftItem.canCollapse = false
        // 左 sidebar は固定幅扱い: window 拡縮の影響を最後に受ける
        leftItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        svc.addSplitViewItem(leftItem)

        let centerVC = NSHostingController(rootView: center())
        let centerItem = NSSplitViewItem(viewController: centerVC)
        centerItem.minimumThickness = centerMin
        centerItem.canCollapse = false
        centerItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
        svc.addSplitViewItem(centerItem)

        let rightVC = NSHostingController(rootView: right())
        let rightItem = NSSplitViewItem(viewController: rightVC)
        rightItem.minimumThickness = rightMin
        rightItem.canCollapse = false
        // window 拡縮の差分は右 (shell) が優先的に吸う
        rightItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 240)
        svc.addSplitViewItem(rightItem)

        context.coordinator.leftVC = leftVC
        context.coordinator.centerVC = centerVC
        context.coordinator.rightVC = rightVC
        return svc
    }

    func updateNSViewController(_ svc: NSSplitViewController, context: Context) {
        if let h = context.coordinator.leftVC as? NSHostingController<L> {
            h.rootView = left()
        }
        if let h = context.coordinator.centerVC as? NSHostingController<C> {
            h.rootView = center()
        }
        if let h = context.coordinator.rightVC as? NSHostingController<R> {
            h.rootView = right()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var leftVC: NSViewController?
        weak var centerVC: NSViewController?
        weak var rightVC: NSViewController?
    }
}

/// Divider ハンドル上でのマウスダウンを捕捉する NSSplitView サブクラス。
/// `splitViewDidResizeSubviews` の `NSSplitViewDividerIndex` userInfo は AppKit が
/// 内部で初期 layout を確定するときにも入ってしまい、ユーザ操作と区別できないため。
private final class DragDetectingSplitView: NSSplitView {
    var onDividerDragStart: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // divider の矩形は arrangedSubviews 間の隙間。dividerThickness 分の幅を持つ。
        let t = dividerThickness
        let subs = arrangedSubviews
        for i in 0..<max(0, subs.count - 1) {
            // isVertical=true (= 縦の divider, 横分割) のとき divider は左 subview の右端から
            // 右隣の subview の左端までの帯。
            let left = subs[i]
            let dividerRect: NSRect
            if isVertical {
                dividerRect = NSRect(x: left.frame.maxX, y: 0, width: t, height: bounds.height)
            } else {
                dividerRect = NSRect(x: 0, y: left.frame.maxY, width: bounds.width, height: t)
            }
            if NSPointInRect(p, dividerRect) {
                onDividerDragStart()
                break
            }
        }
        super.mouseDown(with: event)
    }
}

/// 初期 divider 位置を center:right = initialCenterRatio で適用する SplitViewController。
/// autosave データがあれば AppKit に任せて何もしない。
/// ユーザがまだ divider を直接ドラッグしていない間は viewDidLayout が呼ばれるたびに
/// 比率を再計算する。これで「起動中の中間サイズ (= 1000pt minWidth) で 1 回固定 → その後
/// ウィンドウが最終サイズに復元されても比率がズレる」事故を防ぐ。
/// ユーザのドラッグは splitViewDidResizeSubviews の `NSSplitViewDividerIndex` で検知し、
/// 以降は何もしない (AppKit の autosave に任せる)。
private final class ThreeColumnSplitController: NSSplitViewController {
    var initialCenterRatio: CGFloat = 0.4
    var leftInitial: CGFloat = 140
    var hasAutosavedFrames: Bool = false
    var userHasDragged = false

    override func viewDidLayout() {
        super.viewDidLayout()
        if hasAutosavedFrames || userHasDragged { return }
        let w = splitView.bounds.width
        let remaining = w - leftInitial
        guard remaining > 0 else { return }
        let centerWidth = remaining * initialCenterRatio
        splitView.setPosition(leftInitial, ofDividerAt: 0)
        splitView.setPosition(leftInitial + centerWidth, ofDividerAt: 1)
    }

    // ドラッグ検知は DragDetectingSplitView の mouseDown が `userHasDragged = true` を立てる。
}
