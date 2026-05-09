import SwiftUI

/// プロジェクト一覧と active project を保持する singleton。
///
/// - ピン留めプロジェクトは `~/Library/Application Support/ide/projects.json` に永続化
/// - 一時プロジェクトはプロセス内のみ。アプリ終了で消える
/// - active 切替時のターミナル切替は step4 で実装する
@MainActor
final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    /// ピン留めプロジェクト。手動並び替えされうる順序で保持。
    @Published private(set) var pinned: [Project] = []

    /// 一時プロジェクト。MRU 順（先頭が最近開いた）。
    @Published private(set) var temporary: [Project] = []

    /// 現在アクティブなプロジェクト。サイドバーでのハイライトとターミナル選択に使う。
    @Published private(set) var activeProject: Project?

    /// プロジェクトごとの WorkspaceModel。一度開いた project の shell をバックグラウンドで生かしておく。
    /// close されたときだけ破棄する。
    @Published private(set) var workspaces: [UUID: WorkspaceModel] = [:]

    /// プロジェクトごとのファイルツリーモデル。`fileTree(for:)` で遅延作成。
    @Published private(set) var fileTrees: [UUID: FileTreeModel] = [:]

    /// プロジェクトごとのファイルプレビュー状態。
    @Published private(set) var previews: [UUID: FilePreviewModel] = [:]

    /// プロジェクトごとのファイルインデックス（Cmd+P 用）。
    @Published private(set) var fileIndexes: [UUID: FileIndex] = [:]

    /// Cmd+P クイック検索のオーバーレイ状態。
    @Published var quickSearchVisible: Bool = false
    @Published var quickSearchQuery: String = ""
    @Published var quickSearchSelection: Int = 0

    /// Cmd+Shift+F 全文検索のオーバーレイ状態。
    @Published var fullSearchVisible: Bool = false
    @Published var fullSearchQuery: String = ""
    @Published var fullSearchHits: [SearchHit] = []
    @Published var fullSearchSelection: Int = 0
    @Published var fullSearchInProgress: Bool = false

    /// 「最近使ったプロジェクト」MRU スタック。先頭が最新。確定したタイミングで先頭に push される。
    /// 最大 5 件保持。Ctrl+M オーバーレイの候補ソースに使う。
    @Published private(set) var mruStack: [UUID] = []

    /// Ctrl+M で表示するオーバーレイの状態。nil なら非表示。
    @Published var mruOverlay: MRUOverlayState?

    /// MRU の最大保持数（要件: 直近5件程度）。
    private let mruLimit = 5

    private let store: ProjectsStore

    private init(store: ProjectsStore = .shared) {
        self.store = store
        load()
        applyTestAutoActivate()
        applyTestAutoPreview()
    }

    private func load() {
        let restored = store.load().map { project -> Project in
            // 復元時点では isPinned は必ず true（pinned のみ保存しているので）。
            // 念のため正規化しておく。
            var p = project
            p.isPinned = true
            return p
        }
        self.pinned = restored
    }

    /// `IDE_TEST_AUTO_ACTIVATE_INDEX` 環境変数が設定されている場合、起動時に
    /// 指定インデックスのピン留めプロジェクトをアクティブにする。VERIFY 用デバッグ機能。
    /// 通常は要件通り「再起動時は active を復元しない」挙動。
    private func applyTestAutoActivate() {
        guard let envValue = ProcessInfo.processInfo.environment["IDE_TEST_AUTO_ACTIVATE_INDEX"],
              let index = Int(envValue),
              pinned.indices.contains(index) else { return }
        let target = pinned[index]
        setActive(target)
        PocLog.write("[projects] test-auto-activate index=\(index) name=\(target.displayName)")
    }

    /// `IDE_TEST_AUTO_PREVIEW` 環境変数が active project からの相対パスを指していたら
    /// その file を preview に開く。VERIFY 用デバッグ機能。
    private func applyTestAutoPreview() {
        guard let relPath = ProcessInfo.processInfo.environment["IDE_TEST_AUTO_PREVIEW"],
              let active = activeProject else { return }
        let target = active.path.appendingPathComponent(relPath)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        preview(for: active).open(target)
        PocLog.write("[projects] test-auto-preview \(relPath)")

        if let query = ProcessInfo.processInfo.environment["IDE_TEST_AUTO_FULLSEARCH"] {
            openFullSearch()
            fullSearchQuery = query
            runFullSearch()
        }
    }

    /// 表示順に並べた全プロジェクト（pinned + temporary）。
    var allOrdered: [Project] { pinned + temporary }

    // MARK: - 追加・削除

    /// フォルダパスから一時プロジェクトとして追加。既に同じパスがあれば既存をアクティブにするだけ。
    @discardableResult
    func addTemporary(path: URL) -> Project {
        if let existing = project(at: path) {
            setActive(existing)
            return existing
        }
        let project = Project(path: path)
        temporary.insert(project, at: 0)
        setActive(project)
        return project
    }

    /// プロジェクトを閉じる（一覧から除去）。一時もピン留めも対象。
    /// 開いていた workspace は破棄する（shell プロセスも一緒に解放される）。
    func close(_ project: Project) {
        let wasPinned = project.isPinned
        pinned.removeAll { $0.id == project.id }
        temporary.removeAll { $0.id == project.id }
        workspaces.removeValue(forKey: project.id)
        fileTrees.removeValue(forKey: project.id)
        previews.removeValue(forKey: project.id)
        fileIndexes.removeValue(forKey: project.id)
        if activeProject?.id == project.id {
            activeProject = allOrdered.first
        }
        if wasPinned { persist() }
    }

    // MARK: - Workspace 管理

    /// プロジェクトに紐付く WorkspaceModel を返す。なければ新規作成して dictionary に保持。
    /// 初回作成時に shell プロセスが立ち上がる（PaneState の init 経由）。
    func workspace(for project: Project) -> WorkspaceModel {
        if let existing = workspaces[project.id] { return existing }
        let model = WorkspaceModel(project: project)
        workspaces[project.id] = model
        return model
    }

    /// 現在アクティブなプロジェクトの WorkspaceModel。
    /// アクセスすると workspace を遅延作成する（active なら shell が立ち上がる）。
    var activeWorkspace: WorkspaceModel? {
        guard let active = activeProject else { return nil }
        return workspace(for: active)
    }

    /// プロジェクトに紐付く FileTreeModel を返す。なければ新規作成して dictionary に保持。
    /// 初回作成時にツリースキャンが走る。
    func fileTree(for project: Project) -> FileTreeModel {
        if let existing = fileTrees[project.id] { return existing }
        let model = FileTreeModel(project: project)
        fileTrees[project.id] = model
        return model
    }

    /// プロジェクトに紐付く FilePreviewModel を返す。なければ新規作成。
    func preview(for project: Project) -> FilePreviewModel {
        if let existing = previews[project.id] { return existing }
        let model = FilePreviewModel()
        previews[project.id] = model
        return model
    }

    /// プロジェクトに紐付く FileIndex を返す。なければ新規作成（バックグラウンドで再帰スキャン開始）。
    func fileIndex(for project: Project) -> FileIndex {
        if let existing = fileIndexes[project.id] { return existing }
        let model = FileIndex(project: project)
        fileIndexes[project.id] = model
        return model
    }

    // MARK: - Cmd+P クイック検索

    func openQuickSearch() {
        guard activeProject != nil else { return }
        quickSearchQuery = ""
        quickSearchSelection = 0
        quickSearchVisible = true
    }

    func closeQuickSearch() {
        quickSearchVisible = false
    }

    func quickSearchMoveSelection(_ delta: Int) {
        guard let active = activeProject else { return }
        let total = fileIndex(for: active).search(quickSearchQuery).count
        guard total > 0 else { return }
        let next = (quickSearchSelection + delta) % total
        quickSearchSelection = next < 0 ? total + next : next
    }

    func quickSearchSelect(_ entry: FileIndex.Entry) {
        guard let active = activeProject else { return }
        if !entry.isDirectory {
            preview(for: active).open(entry.url)
            fileIndex(for: active).recordOpen(entry.url)
        }
        closeQuickSearch()
    }

    // MARK: - Cmd+Shift+F 全文検索

    func openFullSearch() {
        guard activeProject != nil else { return }
        fullSearchHits = []
        fullSearchSelection = 0
        fullSearchInProgress = false
        fullSearchVisible = true
    }

    func closeFullSearch() {
        fullSearchVisible = false
    }

    func runFullSearch() {
        guard let active = activeProject else { return }
        let q = fullSearchQuery
        let path = active.path
        fullSearchInProgress = true
        fullSearchHits = []
        fullSearchSelection = 0
        Task.detached { [weak self] in
            let result = FullTextSearcher.run(query: q, in: path)
            await MainActor.run {
                self?.fullSearchHits = result
                self?.fullSearchInProgress = false
            }
        }
    }

    func fullSearchMoveSelection(_ delta: Int) {
        let total = fullSearchHits.count
        guard total > 0 else { return }
        let next = (fullSearchSelection + delta) % total
        fullSearchSelection = next < 0 ? total + next : next
    }

    func fullSearchSelect(_ hit: SearchHit) {
        guard let active = activeProject else { return }
        preview(for: active).open(hit.url)
        fileIndex(for: active).recordOpen(hit.url)
        closeFullSearch()
    }

    // MARK: - ピン留め切替

    func togglePin(_ project: Project) {
        if project.isPinned {
            unpin(project)
        } else {
            pin(project)
        }
        persist()
    }

    private func pin(_ project: Project) {
        guard let idx = temporary.firstIndex(where: { $0.id == project.id }) else { return }
        var p = temporary.remove(at: idx)
        p.isPinned = true
        pinned.append(p)
        if activeProject?.id == p.id { activeProject = p }
    }

    private func unpin(_ project: Project) {
        guard let idx = pinned.firstIndex(where: { $0.id == project.id }) else { return }
        var p = pinned.remove(at: idx)
        p.isPinned = false
        p.lastOpenedAt = .now
        temporary.insert(p, at: 0)
        if activeProject?.id == p.id { activeProject = p }
    }

    // MARK: - アクティブ切替

    func setActive(_ project: Project) {
        var updated = project
        updated.lastOpenedAt = .now

        if let idx = pinned.firstIndex(where: { $0.id == project.id }) {
            pinned[idx] = updated
            persist()
        } else if let idx = temporary.firstIndex(where: { $0.id == project.id }) {
            temporary.remove(at: idx)
            temporary.insert(updated, at: 0)
        }
        let didSwitch = activeProject?.id != updated.id
        activeProject = updated
        // 初回 active 時に workspace を作る（=shell 起動）。2 回目以降は既存を再利用。
        _ = workspace(for: updated)
        // 実際にプロジェクトが切り替わった瞬間に MRU 確定（要件通り）。
        if didSwitch { pushMRU(updated.id) }
    }

    // MARK: - MRU

    /// MRU スタックの先頭にプロジェクト ID を移動（重複は除去、上限 5 件）。
    private func pushMRU(_ id: UUID) {
        mruStack.removeAll { $0 == id }
        mruStack.insert(id, at: 0)
        if mruStack.count > mruLimit { mruStack.removeLast(mruStack.count - mruLimit) }
    }

    /// オーバーレイ用の候補。MRU 順に並べた現存プロジェクト群（close 済みは除外）。
    func mruCandidates() -> [Project] {
        let allById: [UUID: Project] = Dictionary(uniqueKeysWithValues: allOrdered.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result: [Project] = []
        // MRU に載っているもの優先
        for id in mruStack {
            if let p = allById[id], !seen.contains(id) {
                result.append(p)
                seen.insert(id)
            }
        }
        // MRU に未掲載のサイドバー上の project も候補末尾に積む。
        // 要件: 「ピン留め・一時を区別せず、開いてるプロジェクトはすべて MRU の対象」
        // → 「開いてる」= サイドバーに並んでいる全 project と解釈する。
        for p in allOrdered where !seen.contains(p.id) {
            result.append(p)
            seen.insert(p.id)
        }
        return result
    }

    /// Ctrl+M で起動 / 既に起動中なら次の候補にサイクル。
    func openOrCycleMRUOverlay() {
        let candidates = mruCandidates()
        guard !candidates.isEmpty else { return }
        if var current = mruOverlay {
            // サイクル: 次のインデックスへ
            current.selection = (current.selection + 1) % candidates.count
            current.candidates = candidates
            mruOverlay = current
        } else {
            // 起動: 「直前のプロジェクト」（= MRU の 2 番目）にカーソル。1 件しかなければ 0。
            let initial = candidates.count > 1 ? 1 : 0
            mruOverlay = MRUOverlayState(candidates: candidates, selection: initial)
        }
    }

    /// 確定（Ctrl 離した瞬間）: 選択中のプロジェクトを active にして MRU に push。
    func commitMRUOverlay() {
        guard let state = mruOverlay else { return }
        mruOverlay = nil
        guard state.candidates.indices.contains(state.selection) else { return }
        let target = state.candidates[state.selection]
        setActive(target)  // これが pushMRU を呼ぶ
    }

    /// Esc キャンセル: MRU は不変、active も変えない。
    func cancelMRUOverlay() {
        mruOverlay = nil
    }

    // MARK: - 再選択（missing 復旧用）

    /// 指定プロジェクトのパスを別のフォルダに付け替える。displayName も新パスから再生成。
    func relocate(_ project: Project, to newPath: URL) {
        let standardized = newPath.standardizedFileURL
        if let idx = pinned.firstIndex(where: { $0.id == project.id }) {
            pinned[idx].path = standardized
            pinned[idx].displayName = standardized.lastPathComponent
            if activeProject?.id == project.id { activeProject = pinned[idx] }
            persist()
        } else if let idx = temporary.firstIndex(where: { $0.id == project.id }) {
            temporary[idx].path = standardized
            temporary[idx].displayName = standardized.lastPathComponent
            if activeProject?.id == project.id { activeProject = temporary[idx] }
        }
    }

    // MARK: - 検索

    /// 同一の絶対パスを持つプロジェクトを返す（あれば）。
    func project(at path: URL) -> Project? {
        let target = path.standardizedFileURL.path
        return allOrdered.first { $0.path.standardizedFileURL.path == target }
    }

    // MARK: - 永続化

    private func persist() {
        store.save(pinned: pinned)
    }
}
