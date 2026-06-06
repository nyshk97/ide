import SwiftUI

/// 1 プロジェクト分のペインを束ねるモデル。
/// プロジェクトごとに 1 インスタンス。`ProjectsModel` が dictionary で保持する。
@MainActor
final class WorkspaceModel: ObservableObject {
    let project: Project?

    /// 左上ペイン（.split では上、.splitHorizontal では左、.splitFour では左上）
    let topPane: PaneState
    /// メイン作業領域。.singleBottom では唯一の表示ペイン
    let bottomPane: PaneState
    /// 右上ペイン（.splitFour のみ使用）
    let topRightPane: PaneState
    /// 右下ペイン（.splitFour のみ使用）
    let bottomRightPane: PaneState

    /// 全ペイン。`hasUnreadTab` などで使う。
    var allPanes: [PaneState] { [topPane, bottomPane, topRightPane, bottomRightPane] }

    @Published var activePane: PaneState

    /// このワークスペースの全 tab の `realNSView` を抱える portal host。
    /// `WorkspaceView` の root に配置する。tab の親はここに固定され、reparent しない設計
    /// (詳細は `TerminalsHostView` の doc 参照)。
    let terminalsHost: TerminalsHostView = TerminalsHostView()

    /// ペイン構成。`private(set)` にして全変更を `setPaneLayout` 経由に統一する。
    /// `didSet` で `ProjectsModel.updatePaneLayout` を呼んで自動 persist。
    @Published private(set) var paneLayout: PaneLayout {
        didSet {
            guard paneLayout != oldValue else { return }
            if let projectID = project?.id {
                ProjectsModel.shared.updatePaneLayout(projectID: projectID, layout: paneLayout)
            }
        }
    }

    init(project: Project?) {
        self.project = project
        let cwd = project?.path
        let top = PaneState(cwd: cwd)
        let bottom = PaneState(cwd: cwd)
        let topRight = PaneState(cwd: cwd)
        let bottomRight = PaneState(cwd: cwd)
        self.topPane = top
        self.bottomPane = bottom
        self.topRightPane = topRight
        self.bottomRightPane = bottomRight
        // 初期フォーカスは下ペイン（「下大ターミナル」がメイン作業領域の想定）
        self.activePane = bottom
        self.paneLayout = project?.paneLayout ?? .split
    }

    func setActive(_ pane: PaneState) {
        if pane !== activePane {
            activePane = pane
        }
        pane.activeTab?.hasUnreadNotification = false
        ProjectsModel.shared.refreshUnreadProjects()
    }

    func isActive(_ pane: PaneState) -> Bool {
        pane === activePane
    }

    /// Cmd+Opt+↑/↓ 用。指定のペインにフォーカスを移す（既にそのペインなら no-op）。
    func focusPane(_ target: PaneState) {
        guard target !== activePane else { return }
        if let view = target.activeTab?.realNSView,
           let window = view.window,
           window.makeFirstResponder(view) {
            return
        }
        setActive(target)
    }

    /// タブを閉じる。最後の 1 個を閉じたときの挙動は `handlePaneEmpty` 参照。
    ///
    /// **Phase 3 portal host 方式での重要な掃除手順**:
    /// - `terminalsHost.detach(...)` で host の subview 配列から外す。
    /// - `releaseSurface()` を即時呼んで PTY を解放。
    func closeTab(in pane: PaneState, at index: Int) {
        guard pane.tabs.indices.contains(index) else { return }
        let removed = pane.tabs[index]
        let wasActiveInActivePane = (pane === activePane && pane.activeIndex == index)

        terminalsHost.detach(removed.realNSView)
        removed.realNSView.releaseSurface()
        pane.tabs.remove(at: index)

        if pane.tabs.isEmpty {
            handlePaneEmpty(pane)
        } else if index < pane.activeIndex {
            pane.activeIndex -= 1
        } else if pane.activeIndex >= pane.tabs.count {
            pane.activeIndex = pane.tabs.count - 1
        }

        if wasActiveInActivePane, let newActive = activePane.activeTab,
           let window = newActive.realNSView.window {
            window.makeFirstResponder(newActive.realNSView)
        }

        ProjectsModel.shared.refreshUnreadProjects()
    }

    /// アクティブペインのアクティブタブを閉じる。`Cmd+W` 経路で使う。
    func closeActiveTabOfActivePane() {
        closeTab(in: activePane, at: activePane.activeIndex)
    }

    /// タブをペイン間で移動する。D&D と `Cmd+Shift+Opt+↑/↓` の両方から呼ばれる。
    func moveTab(_ tabID: UUID, from sourcePane: PaneState, to targetPane: PaneState, before beforeTabID: UUID?) {
        guard sourcePane !== targetPane else { return }
        guard let sourceIndex = sourcePane.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let wasActiveInSource = sourcePane.activeIndex == sourceIndex

        let movedTab = sourcePane.tabs.remove(at: sourceIndex)

        let insertIndex: Int
        if let beforeTabID, let idx = targetPane.tabs.firstIndex(where: { $0.id == beforeTabID }) {
            insertIndex = idx
        } else {
            insertIndex = targetPane.tabs.count
        }
        targetPane.tabs.insert(movedTab, at: insertIndex)

        if !sourcePane.tabs.isEmpty {
            if wasActiveInSource {
                sourcePane.activeIndex = min(sourceIndex, sourcePane.tabs.count - 1)
            } else if sourceIndex < sourcePane.activeIndex {
                sourcePane.activeIndex -= 1
            }
        }

        targetPane.activeIndex = insertIndex
        activePane = targetPane

        movedTab.realNSView.pane = targetPane
        if let window = movedTab.realNSView.window {
            window.makeFirstResponder(movedTab.realNSView)
        }

        if sourcePane.tabs.isEmpty {
            handlePaneEmpty(sourcePane)
        }

        ProjectsModel.shared.refreshUnreadProjects()
    }

    /// レイアウトを切り替える。オフスクリーン退避・タブ補充・activePane 補正をまとめて行う。
    /// `paneLayout` は `private(set)` のためすべての変更はここ経由。
    func setPaneLayout(_ layout: PaneLayout) {
        guard layout != paneLayout else { return }

        // 新レイアウトで非表示になるペインのアクティブタブをオフスクリーンへ退避。
        // 非アクティブタブは TerminalAnchorView.isActive==false で既に (-10000,-10000) 済み。
        let toHide: [PaneState]
        switch layout {
        case .singleBottom:
            // topPane は collapsed AnchorView が残るが、splitFour からの遷移で一時アンマウントされる
            // 経路があるため退避対象に含める
            toHide = [topPane, topRightPane, bottomRightPane]
        case .split, .splitHorizontal:
            toHide = [topRightPane, bottomRightPane]
        case .splitFour:
            toHide = []
        }
        for p in toHide {
            if let view = p.activeTab?.realNSView {
                terminalsHost.setGeometry(for: view, frame: .zero, isActive: false)
            }
        }

        // 新レイアウトで使用するペインにタブを補充
        switch layout {
        case .singleBottom:
            break
        case .split, .splitHorizontal:
            if topPane.tabs.isEmpty { topPane.addTab() }
        case .splitFour:
            if topPane.tabs.isEmpty { topPane.addTab() }
            if topRightPane.tabs.isEmpty { topRightPane.addTab() }
            if bottomRightPane.tabs.isEmpty { bottomRightPane.addTab() }
        }

        paneLayout = layout

        // activePane が非表示ペインに残っていたら bottomPane へ移す
        if !visiblePanes(for: layout).contains(where: { $0 === activePane }) {
            focusPane(bottomPane)
        }
    }

    /// ペインのタブが 0 になったときの遷移ルール。
    func handlePaneEmpty(_ pane: PaneState) {
        switch paneLayout {
        case .split, .splitHorizontal:
            if pane === topPane {
                // 左/上ペインが空になったら 1 ペインに降格
                setPaneLayout(.singleBottom)
            } else {
                pane.addTab()
            }
        case .splitFour, .singleBottom:
            pane.addTab()
        }
    }

    /// いずれかのペインのタブに未読通知があるか。サイドバーのリング表示に使う。
    var hasUnreadTab: Bool {
        allPanes.flatMap(\.tabs).contains { $0.hasUnreadNotification }
    }

    /// 与えられたタブが「真にアクティブ」（active pane の active tab）か。
    func isCurrentlyActive(tab: TerminalTab) -> Bool {
        activePane.activeTab === tab
    }

    // MARK: - Private helpers

    private func visiblePanes(for layout: PaneLayout) -> [PaneState] {
        switch layout {
        case .singleBottom:             return [bottomPane]
        case .split, .splitHorizontal:  return [topPane, bottomPane]
        case .splitFour:                return [topPane, bottomPane, topRightPane, bottomRightPane]
        }
    }
}
