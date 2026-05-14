import SwiftUI

/// IDE 全体のルートレイアウト（3 カラム）。
/// 左: プロジェクト一覧サイドバー / 中央: ファイルツリー or プレビュー / 右: ターミナル。
/// ペイン比率は `HSplitView` のドラッグハンドルで変更でき、保存はしない（要件通り）。
struct RootLayoutView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    var body: some View {
        // 左サイドバーだけ maxWidth で抑える。中央ペインは maxWidth を付けると、
        // プレビュー ↔ ツリー切替時の再レイアウトでドラッグ拡大が snap back されるため
        // 上限なしにしてユーザーの拡張を維持する。
        //
        // 初期幅は固定の idealWidth で決める。以前は GeometryReader でウィンドウ幅に対する
        // 比率（中央 40%）で算出していたが、起動直後やフルスクリーン遷移直後は
        // GeometryReader が一時的に小さいサイズを返し、その時点で HSplitView が
        // 各ペインの幅を確定してしまう（以降のリサイズ分は右ペインに吸われる）ため、
        // どの画面でもファイルツリーが狭いまま固定されていた。固定値なら確実に効く。
        HSplitView {
            LeftSidebarView()
                .frame(minWidth: 120, idealWidth: 140, maxWidth: 180)
            CenterPaneView()
                .frame(minWidth: 240, idealWidth: 540)
            rightArea
                .frame(minWidth: 400)
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
