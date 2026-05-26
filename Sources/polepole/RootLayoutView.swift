import AppKit
import SwiftUI

/// PolePole 全体のルートレイアウト（4 カラム）。
/// 左: プロジェクト一覧サイドバー / ツリー / プレビュー / ターミナル。
///
/// - プロジェクト一覧サイドバーは折り畳み可能（グローバル状態 `ProjectsModel.sidebarCollapsed`）。
///   折り畳むと左端に幅 12pt の復帰ハンドルが現れ、クリックで展開できる。
/// - プレビューペインは active project ごとに表示/非表示を切替（`activePreviewVisible`）。
///   `isCollapsed` をトグルするだけなので divider 数と autosave のフォーマットは変わらず安定。
///
/// 幅は `NSSplitView.autosaveName` で永続化。3 カラム時代の `polepole.rootSplit` とは
/// 形式が違うので autosaveName を v2 に切替えて既存幅は破棄する。
struct RootLayoutView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    var body: some View {
        FourColumnSplit(
            autosaveName: "polepole.rootSplit.v2",
            sidebarCollapsed: projects.sidebarCollapsed,
            previewVisible: projects.activePreviewVisible,
            initialTerminalRatio: 0.45,
            sidebarMin: 120,
            sidebarInitial: 140,
            sidebarMax: 220,
            treeMin: 180,
            treeInitial: 240,
            previewMin: 320,
            previewInitial: 420,
            terminalMin: 360,
            onSidebarCollapseDidChange: { collapsed in
                // AppKit 側で isCollapsed が変わった（divider drag → minimumThickness で auto-collapse、
                // または autosave 復元）ときに state を sync する。
                // updateNSViewController 側に「現在値と異なるときだけ書く」ガードがあるので無限ループしない。
                if projects.sidebarCollapsed != collapsed {
                    projects.sidebarCollapsed = collapsed
                }
            },
            onPreviewCollapseDidChange: { collapsed in
                // drag で preview pane を閉じたら、active project の preview.close() を呼んで
                // activePreviewVisible も false に揃える。
                if collapsed, let active = projects.activeProject {
                    let preview = projects.preview(for: active)
                    if preview.currentURL != nil {
                        preview.close()
                    }
                }
            }
        ) {
            LeftSidebarView()
        } tree: {
            FileTreePaneView()
        } preview: {
            FilePreviewPaneView()
        } terminal: {
            rightArea
        }
        .overlay(alignment: .leading) {
            if projects.sidebarCollapsed {
                SidebarRestoreHandle(onExpand: { projects.sidebarCollapsed = false })
            }
        }
        .overlay(alignment: .center) {
            if let state = projects.mruOverlay {
                MRUOverlayView(state: state)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if projects.quickSearchVisible, let active = projects.activeProject {
                ZStack {
                    // 枠外クリックで閉じる用の透明レイヤー。Color.clear は hit-test されないので
                    // ほぼ透明な opacity を載せた Color にする。子の検索 view へのタップは
                    // SwiftUI のヒットテストで子が先に消費するためここには届かない。
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { projects.closeQuickSearch() }
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
                }
            } else if projects.fullSearchVisible {
                ZStack {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { projects.closeFullSearch() }
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
                }
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

/// サイドバー折畳中だけ左端に出る復帰ハンドル。
/// 幅 14pt、`>` アイコン。クリックでサイドバーを展開する。
/// 視認性のため accent カラーで薄く塗る（ホバーで濃く）。
/// tooltip にはリバインド可能な toggleSidebar ショートカットを表示する。
private struct SidebarRestoreHandle: View {
    @ObservedObject private var shortcuts = ShortcutsStore.shared
    let onExpand: () -> Void
    @State private var hovered: Bool = false

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hovered ? Color.white : Color.primary.opacity(0.85))
                .frame(width: 14, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered ? Color.accentColor.opacity(0.85) : Color.accentColor.opacity(0.35))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show project sidebar (\(shortcuts.combo(for: .toggleSidebar).display))")
        .frame(maxHeight: .infinity, alignment: .center)
        // overlay 自身は alignment: .leading に置かれるが、divider との接触を避けるため
        // 左に 2pt だけ寄せる。
        .padding(.leading, 2)
    }
}

/// 4 カラム横分割。`autosaveName` で各 divider 位置を AppKit に永続化させる。
/// `sidebarCollapsed` / `previewVisible` を `updateNSViewController` で SplitViewItem.isCollapsed に反映する。
/// 逆方向（drag で divider を寄せて AppKit が isCollapsed=true にしたケース）は KVO で観察し、
/// `onSidebarCollapseDidChange` / `onPreviewCollapseDidChange` でモデルに sync する。
/// 双方向同期があると `updateNSViewController` で「現在値と異なるときだけ書く」ガードと組み合わせて
/// 無限ループにはならない。
/// アニメーションは drag 中との競合を避けるため `animator()` 経由は使わず即時切替。
private struct FourColumnSplit<L: View, T: View, P: View, R: View>: NSViewControllerRepresentable {
    let autosaveName: String
    let sidebarCollapsed: Bool
    let previewVisible: Bool
    let initialTerminalRatio: CGFloat
    let sidebarMin: CGFloat
    let sidebarInitial: CGFloat
    let sidebarMax: CGFloat
    let treeMin: CGFloat
    let treeInitial: CGFloat
    let previewMin: CGFloat
    let previewInitial: CGFloat
    let terminalMin: CGFloat
    let onSidebarCollapseDidChange: (Bool) -> Void
    let onPreviewCollapseDidChange: (Bool) -> Void
    let leftBuilder: () -> L
    let treeBuilder: () -> T
    let previewBuilder: () -> P
    let terminalBuilder: () -> R

    init(
        autosaveName: String,
        sidebarCollapsed: Bool,
        previewVisible: Bool,
        initialTerminalRatio: CGFloat,
        sidebarMin: CGFloat, sidebarInitial: CGFloat, sidebarMax: CGFloat,
        treeMin: CGFloat, treeInitial: CGFloat,
        previewMin: CGFloat, previewInitial: CGFloat,
        terminalMin: CGFloat,
        onSidebarCollapseDidChange: @escaping (Bool) -> Void,
        onPreviewCollapseDidChange: @escaping (Bool) -> Void,
        @ViewBuilder left: @escaping () -> L,
        @ViewBuilder tree: @escaping () -> T,
        @ViewBuilder preview: @escaping () -> P,
        @ViewBuilder terminal: @escaping () -> R
    ) {
        self.autosaveName = autosaveName
        self.sidebarCollapsed = sidebarCollapsed
        self.previewVisible = previewVisible
        self.initialTerminalRatio = initialTerminalRatio
        self.sidebarMin = sidebarMin
        self.sidebarInitial = sidebarInitial
        self.sidebarMax = sidebarMax
        self.treeMin = treeMin
        self.treeInitial = treeInitial
        self.previewMin = previewMin
        self.previewInitial = previewInitial
        self.terminalMin = terminalMin
        self.onSidebarCollapseDidChange = onSidebarCollapseDidChange
        self.onPreviewCollapseDidChange = onPreviewCollapseDidChange
        self.leftBuilder = left
        self.treeBuilder = tree
        self.previewBuilder = preview
        self.terminalBuilder = terminal
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let svc = FourColumnSplitController()
        svc.sidebarInitial = sidebarInitial
        svc.treeInitial = treeInitial
        svc.previewInitial = previewInitial
        svc.terminalInitialRatio = initialTerminalRatio
        let custom = DragDetectingSplitView()
        custom.onDividerDragStart = { [weak svc] in svc?.userHasDragged = true }
        svc.splitView = custom
        svc.splitView.isVertical = true
        svc.splitView.dividerStyle = .thin
        // 既存の "polepole.rootSplit"（3 カラム時代）とは divider 数が違うので、
        // 新キー名を使って既存の保存値は破棄する。
        let key = "NSSplitView Subview Frames \(autosaveName)"
        svc.hasAutosavedFrames = UserDefaults.standard.object(forKey: key) != nil
        svc.splitView.autosaveName = NSSplitView.AutosaveName(autosaveName)

        // 1) サイドバー（プロジェクト一覧）
        let leftVC = NSHostingController(rootView: leftBuilder())
        let leftItem = NSSplitViewItem(viewController: leftVC)
        leftItem.minimumThickness = sidebarMin
        leftItem.maximumThickness = sidebarMax
        leftItem.canCollapse = true
        leftItem.isCollapsed = sidebarCollapsed
        leftItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)
        svc.addSplitViewItem(leftItem)

        // 2) ファイルツリー
        let treeVC = NSHostingController(rootView: treeBuilder())
        let treeItem = NSSplitViewItem(viewController: treeVC)
        treeItem.minimumThickness = treeMin
        treeItem.canCollapse = false
        treeItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 250)
        svc.addSplitViewItem(treeItem)

        // 3) プレビュー（初期は閉、active project の preview に応じて開閉）
        let previewVC = NSHostingController(rootView: previewBuilder())
        let previewItem = NSSplitViewItem(viewController: previewVC)
        previewItem.minimumThickness = previewMin
        previewItem.canCollapse = true
        previewItem.isCollapsed = !previewVisible
        previewItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 245)
        svc.addSplitViewItem(previewItem)

        // 4) ターミナル
        let terminalVC = NSHostingController(rootView: terminalBuilder())
        let terminalItem = NSSplitViewItem(viewController: terminalVC)
        terminalItem.minimumThickness = terminalMin
        terminalItem.canCollapse = false
        terminalItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 240)
        svc.addSplitViewItem(terminalItem)

        context.coordinator.leftVC = leftVC
        context.coordinator.treeVC = treeVC
        context.coordinator.previewVC = previewVC
        context.coordinator.terminalVC = terminalVC

        // drag で divider を寄せて AppKit が自動 collapse したケースをモデルに sync する。
        // SplitViewItem の isCollapsed は KVO 可能。observation は Coordinator に保持。
        // KVO closure は @Sendable 推測なので、closure 内では item から Bool だけ抜き出し、
        // callback は nonisolated(unsafe) で Sendable opt-out してから MainActor の Task で呼び戻す。
        nonisolated(unsafe) let onSidebar = onSidebarCollapseDidChange
        nonisolated(unsafe) let onPreview = onPreviewCollapseDidChange
        context.coordinator.sidebarObs = leftItem.observe(\.isCollapsed, options: [.new]) { item, _ in
            let value = item.isCollapsed
            Task { @MainActor in onSidebar(value) }
        }
        context.coordinator.previewObs = previewItem.observe(\.isCollapsed, options: [.new]) { item, _ in
            let value = item.isCollapsed
            Task { @MainActor in onPreview(value) }
        }
        return svc
    }

    func updateNSViewController(_ svc: NSSplitViewController, context: Context) {
        if let h = context.coordinator.leftVC as? NSHostingController<L> {
            h.rootView = leftBuilder()
        }
        if let h = context.coordinator.treeVC as? NSHostingController<T> {
            h.rootView = treeBuilder()
        }
        if let h = context.coordinator.previewVC as? NSHostingController<P> {
            h.rootView = previewBuilder()
        }
        if let h = context.coordinator.terminalVC as? NSHostingController<R> {
            h.rootView = terminalBuilder()
        }

        // collapse 状態の反映（animator() は drag 競合を避けるため使わない）
        let items = svc.splitViewItems
        if items.count >= 4 {
            if items[0].isCollapsed != sidebarCollapsed {
                items[0].isCollapsed = sidebarCollapsed
            }
            let wantPreviewCollapsed = !previewVisible
            if items[2].isCollapsed != wantPreviewCollapsed {
                items[2].isCollapsed = wantPreviewCollapsed
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var leftVC: NSViewController?
        weak var treeVC: NSViewController?
        weak var previewVC: NSViewController?
        weak var terminalVC: NSViewController?
        var sidebarObs: NSKeyValueObservation?
        var previewObs: NSKeyValueObservation?
    }
}

/// Divider ハンドル上でのマウスダウンを捕捉する NSSplitView サブクラス。
/// `splitViewDidResizeSubviews` の `NSSplitViewDividerIndex` userInfo は AppKit が
/// 内部で初期 layout を確定するときにも入ってしまい、ユーザ操作と区別できないため。
private final class DragDetectingSplitView: NSSplitView {
    var onDividerDragStart: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = dividerThickness
        let subs = arrangedSubviews
        for i in 0..<max(0, subs.count - 1) {
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

/// 初期 divider 位置を 4 ペイン用に適用する。autosave データがあれば AppKit に任せる。
/// 起動初回はプレビューが collapsed の前提で「サイドバー + ツリー + ターミナル」の 3 領域に
/// 残り幅を割り当てる。
private final class FourColumnSplitController: NSSplitViewController {
    var sidebarInitial: CGFloat = 140
    var treeInitial: CGFloat = 240
    var previewInitial: CGFloat = 420
    var terminalInitialRatio: CGFloat = 0.45
    var hasAutosavedFrames: Bool = false
    var userHasDragged = false

    override func viewDidLayout() {
        super.viewDidLayout()
        if hasAutosavedFrames || userHasDragged { return }
        let w = splitView.bounds.width
        guard w > 0 else { return }
        // プレビューが initial state で collapsed なら 3 領域に分配。
        // 1 列目 = sidebarInitial 固定 / 2 列目 = treeInitial 固定 / 残りがターミナル。
        // setPosition(_:ofDividerAt:) の divider index は collapsed item があっても
        // arrangedSubviews 上の位置に紐づく。
        splitView.setPosition(sidebarInitial, ofDividerAt: 0)
        splitView.setPosition(sidebarInitial + treeInitial, ofDividerAt: 1)
        // divider 2: tree-end | preview-end。プレビュー collapsed なら preview の幅は 0 扱い、
        // divider 2 は divider 1 と同位置になる。展開時はその位置から右に previewInitial 分。
        splitView.setPosition(sidebarInitial + treeInitial + previewInitial, ofDividerAt: 2)
    }
}
