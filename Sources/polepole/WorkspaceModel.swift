import SwiftUI

/// 1 プロジェクト分の上下 2 ペインを束ねるモデル。
/// プロジェクトごとに 1 インスタンス。`ProjectsModel` が dictionary で保持する。
@MainActor
final class WorkspaceModel: ObservableObject {
    let project: Project?

    let topPane: PaneState
    let bottomPane: PaneState

    @Published var activePane: PaneState

    /// このワークスペースの全 tab の `realNSView` を抱える portal host。
    /// `WorkspaceView` の root に配置する。tab の親はここに固定され、reparent しない設計
    /// (詳細は `TerminalsHostView` の doc 参照)。
    let terminalsHost: TerminalsHostView = TerminalsHostView()

    /// 上下分割 / 下のみ。プロジェクトごとに `Project.paneLayout` として永続化される。
    /// `didSet` で `ProjectsModel.updatePaneLayout` を呼んで自動 persist。
    @Published var paneLayout: PaneLayout {
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
        self.topPane = top
        self.bottomPane = bottom
        // 初期フォーカスは下ペイン（「下大ターミナル」がメイン作業領域の想定）
        self.activePane = bottom
        self.paneLayout = project?.paneLayout ?? .split
    }

    func setActive(_ pane: PaneState) {
        if pane !== activePane {
            activePane = pane
        }
        // active になったペインのカレントタブの未読通知をクリア
        pane.activeTab?.hasUnreadNotification = false
        ProjectsModel.shared.refreshUnreadProjects()
    }

    func isActive(_ pane: PaneState) -> Bool {
        pane === activePane
    }

    /// Cmd+Opt+↑/↓ 用。指定のペインにフォーカスを移す（既にそのペインなら no-op）。
    /// target pane の active tab に対応する NSView を first responder にすると、
    /// becomeFirstResponder の既存フローで setActive とアクティブ化が連動する。
    func focusPane(_ target: PaneState) {
        guard target !== activePane else { return }
        // window 取れ & makeFirstResponder が成功した場合のみ早期 return。
        // 上記いずれかが欠ければ fallback で activePane だけでも動かす（setActive を呼ぶことで
        // タブバーのハイライト等の表示は追従する。キー入力は次のクリック等で正しい view に入る）。
        if let view = target.activeTab?.realNSView,
           let window = view.window,
           window.makeFirstResponder(view) {
            return
        }
        setActive(target)
    }

    /// タブを閉じる。最後の 1 個を閉じたときの挙動はペインに応じて分岐する（`handlePaneEmpty` 参照）。
    /// `PaneState.closeTab` の自動 addTab + refreshUnreadProjects 責務をここに集約。
    ///
    /// **Phase 3 portal host 方式での重要な掃除手順**:
    /// - `terminalsHost.detach(...)` で host の subview 配列から外す。これをしないと閉じたタブの
    ///   `realNSView` が画面に残り続け、描画残り・hit target 残留・firstResponder 残留・subview 蓄積
    ///   につながる (host は subview を強参照する)。
    /// - `releaseSurface()` を即時呼んで PTY を解放。`TerminalTab.deinit` でも呼ばれるが、host が
    ///   subview として `realNSView` を強参照していると TerminalTab の deinit が遅延するので、ここで
    ///   明示的にやる。
    func closeTab(in pane: PaneState, at index: Int) {
        guard pane.tabs.indices.contains(index) else { return }
        let removed = pane.tabs[index]
        let wasActiveInActivePane = (pane === activePane && pane.activeIndex == index)

        // 1. host から実体 NSView を外す (subview 強参照を切る)
        terminalsHost.detach(removed.realNSView)
        // 2. surface を即時解放 (PTY kill)
        removed.realNSView.releaseSurface()
        // 3. tabs から remove
        pane.tabs.remove(at: index)

        if pane.tabs.isEmpty {
            handlePaneEmpty(pane)
        } else if index < pane.activeIndex {
            pane.activeIndex -= 1
        } else if pane.activeIndex >= pane.tabs.count {
            pane.activeIndex = pane.tabs.count - 1
        }

        // 閉じたタブが active だった場合、firstResponder が浮かないよう
        // 新しい active tab (or 自動遷移後の activePane.activeTab) に focus を移す。
        if wasActiveInActivePane, let newActive = activePane.activeTab,
           let window = newActive.realNSView.window {
            window.makeFirstResponder(newActive.realNSView)
        }

        // 未読タブを閉じた可能性があるのでサイドバーのリングを再計算
        ProjectsModel.shared.refreshUnreadProjects()
    }

    /// アクティブペインのアクティブタブを閉じる。`Cmd+W` 経路で使う。
    func closeActiveTabOfActivePane() {
        closeTab(in: activePane, at: activePane.activeIndex)
    }

    /// タブをペイン間で移動する。D&D とキーボードショートカット (`Cmd+Shift+Opt+↑/↓`) の両方から呼ばれる。
    /// `beforeTabID == nil` は targetPane の末尾に挿入。
    /// 同一ペイン (sourcePane === targetPane) のときは `PaneState.moveTab` を呼ぶこと (責務分離)。
    ///
    /// 新設計 (Phase 3 portal host 方式) では `tab.realNSView` は `terminalsHost` に固定 attach 済みで、
    /// 移動時に reparent しない。`activePane` 切替で次の layout pass で anchor frame が新ペインに移り、
    /// `realNSView.frame` がそれに追従して見た目が動く。
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

        // source 側の activeIndex 整合
        if !sourcePane.tabs.isEmpty {
            if wasActiveInSource {
                sourcePane.activeIndex = min(sourceIndex, sourcePane.tabs.count - 1)
            } else if sourceIndex < sourcePane.activeIndex {
                sourcePane.activeIndex -= 1
            }
        }

        // target 側は移動したタブを active に
        targetPane.activeIndex = insertIndex

        // active pane を target に明示遷移 (見た目の active tab と active pane がズレないように)
        activePane = targetPane

        // realNSView.pane を targetPane に張り替えてから makeFirstResponder。
        // SwiftUI の updateNSView は次 render cycle で走るので、ここで張り替えないと
        // becomeFirstResponder が wrong pane (= sourcePane) を active にしてしまう。
        movedTab.realNSView.pane = targetPane
        if let window = movedTab.realNSView.window {
            window.makeFirstResponder(movedTab.realNSView)
        }

        // source が空なら自動遷移 (上ペインなら 1 ペイン化、下ペインなら新規タブ補充)
        if sourcePane.tabs.isEmpty {
            handlePaneEmpty(sourcePane)
        }

        ProjectsModel.shared.refreshUnreadProjects()
    }

    /// `.split` ⇔ `.singleBottom` を切替える。`Cmd+Opt+\` と TabsView の分割追加ボタンから呼ぶ。
    /// - `.split → .singleBottom`: activePane を bottomPane に明示遷移
    ///   （畳まれた上ペインに `Cmd+T` / `Cmd+W` が効かないように）
    /// - `.singleBottom → .split`: 上ペインが空ならタブを 1 つ用意
    ///   （「空のまま split」を作らないため）
    func togglePaneLayout() {
        switch paneLayout {
        case .split:
            paneLayout = .singleBottom
            if activePane === topPane {
                activePane = bottomPane
            }
        case .singleBottom:
            if topPane.tabs.isEmpty {
                topPane.addTab()
            }
            paneLayout = .split
        }
    }

    /// ペインのタブが 0 になったときの遷移ルール。
    /// - 上ペインで `.split` 中なら `.singleBottom` に切替えて上ペインを畳む。activePane も bottom に移す
    ///   （畳まれた上ペインに `Cmd+T` / `Cmd+W` が効いてしまうのを防ぐ）。
    /// - それ以外（下ペイン or 1 ペイン中の唯一ペイン）は新規タブを 1 つ自動生成する。
    func handlePaneEmpty(_ pane: PaneState) {
        if pane === topPane && paneLayout == .split {
            paneLayout = .singleBottom
            activePane = bottomPane
        } else {
            pane.addTab()
        }
    }

    /// 上下どちらかのペインのいずれかのタブに未読通知があるか。
    /// サイドバーのプロジェクトリング表示の派生元。
    var hasUnreadTab: Bool {
        topPane.tabs.contains { $0.hasUnreadNotification }
            || bottomPane.tabs.contains { $0.hasUnreadNotification }
    }

    /// 与えられたタブが「真にアクティブ」（active pane の active tab）か。
    /// BEL 通知で「アクティブ時は無視」の判定に使う。
    func isCurrentlyActive(tab: TerminalTab) -> Bool {
        activePane.activeTab === tab
    }
}
