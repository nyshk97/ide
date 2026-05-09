import SwiftUI

/// IDE 全体のルートレイアウト（3 カラム）。
/// 左: プロジェクト一覧サイドバー / 中央: ファイルツリー or プレビュー / 右: ターミナル。
/// ペイン比率は `HSplitView` のドラッグハンドルで変更でき、保存はしない（要件通り）。
struct RootLayoutView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    var body: some View {
        // SwiftUI の HSplitView は idealWidth を尊重せず初期は均等分割になりがちなので、
        // maxWidth で起動時の幅レンジを絞り、右ペイン（ターミナル）だけ無限に伸びるようにする。
        HSplitView {
            LeftSidebarView()
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 240)
            CenterPaneView()
                .frame(minWidth: 200, idealWidth: 320, maxWidth: 480)
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
                Text("プロジェクトを開くとターミナルが起動します")
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
