import SwiftUI

/// プロジェクト一覧と active project を保持する singleton。
///
/// - pinned / temporary 両方を `~/Library/Application Support/ide/projects.json` に永続化
///   （明示的に「閉じる」しない限りサイドバーから消えない）
/// - pinned は手動並び替えされうる順序、temporary は MRU 順（先頭が最近開いた）
/// - active project は永続化しない（再起動時はリセット）
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

    /// 配下のいずれかのタブに未読通知（AI ツールの完了 BEL）があるプロジェクトの id 集合。
    /// サイドバーのアバターにリングを表示するのに使う。`refreshUnreadProjects()` で更新する。
    @Published private(set) var unreadProjectIDs: Set<UUID> = []

    /// プロジェクトごとのファイルツリーモデル。`fileTree(for:)` で遅延作成。
    @Published private(set) var fileTrees: [UUID: FileTreeModel] = [:]

    /// プロジェクトごとのファイルプレビュー状態。
    @Published private(set) var previews: [UUID: FilePreviewModel] = [:]

    /// プロジェクトごとのファイルインデックス（Cmd+P 用）。
    @Published private(set) var fileIndexes: [UUID: FileIndex] = [:]

    /// 中央ペインのファイルツリーがキーボードフォーカスを持っているか。
    /// `FileTreeView` が @FocusState を同期する。`MRUKeyMonitor` の Cmd+R 判定に使う。
    @Published var fileTreeFocused: Bool = false

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
        // 未読フラグ → アクティブ化の順。こうしておくと AUTO_ACTIVATE と UNREAD_INDICES を
        // 同じプロジェクトに向けたとき「アクティブ化でそのプロジェクトの表示タブの未読が消える」
        // 挙動も検証できる。
        applyTestUnreadIndices()
        applyTestAutoActivate()
        applyTestAutoPreview()
    }

    private func load() {
        let restored = store.load()
        // pinned / temporary とも保存時の順序をそのまま復元する。
        // temporary はかつて lastOpenedAt 降順で並べていたが、ドラッグ並び替えを導入した
        // タイミングで「ユーザーが手で決めた順を尊重」する方針に変更した（mruStack は別管理）。
        self.pinned = restored.filter { $0.isPinned }
        self.temporary = restored.filter { !$0.isPinned }
    }

    /// `IDE_TEST_AUTO_ACTIVATE_INDEX` 環境変数が設定されている場合、起動時に
    /// 指定インデックスのプロジェクト（allOrdered = pinned + temporary）をアクティブにする。
    /// VERIFY 用デバッグ機能。通常は要件通り「再起動時は active を復元しない」挙動。
    private func applyTestAutoActivate() {
        guard let envValue = ProcessInfo.processInfo.environment["IDE_TEST_AUTO_ACTIVATE_INDEX"],
              let index = Int(envValue) else { return }
        let ordered = allOrdered
        guard ordered.indices.contains(index) else { return }
        let target = ordered[index]
        setActive(target)
        Logger.shared.debug("[projects] test-auto-activate index=\(index) name=\(target.displayName)")
    }

    /// `IDE_TEST_AUTO_PREVIEW` 環境変数が active project からの相対パスを指していたら
    /// その file を preview に開く。VERIFY 用デバッグ機能。
    private func applyTestAutoPreview() {
        let env = ProcessInfo.processInfo.environment

        if let relPath = env["IDE_TEST_AUTO_PREVIEW"],
           let active = activeProject {
            let target = active.path.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: target.path) {
                preview(for: active).open(target)
                Logger.shared.debug("[projects] test-auto-preview \(relPath)")
            }
        }

        if let query = env["IDE_TEST_PREVIEW_FIND"], let active = activeProject {
            let p = preview(for: active)
            if p.currentURL != nil {
                p.findQuery = query
                p.showFindBar()
                Logger.shared.debug("[projects] test-preview-find \(query)")
            }
        }

        if let query = env["IDE_TEST_AUTO_FULLSEARCH"] {
            openFullSearch()
            fullSearchQuery = query
            runFullSearch()
        }

        if let toast = env["IDE_TEST_TOAST"] {
            // ErrorBus は MainActor、init からの呼び出しは MainActor 隔離なので OK
            ErrorBus.shared.notify(toast, kind: .error)
        }
    }

    /// `IDE_TEST_UNREAD_INDICES=0,2` のように指定すると、allOrdered の該当インデックスの
    /// プロジェクトの workspace を作成し、下ペインのカレントタブに未読通知を立てる。
    /// サイドバーのリング表示の VERIFY 用デバッグ機能。
    private func applyTestUnreadIndices() {
        guard let raw = ProcessInfo.processInfo.environment["IDE_TEST_UNREAD_INDICES"] else { return }
        let indices = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let ordered = allOrdered
        for index in indices where ordered.indices.contains(index) {
            let wm = workspace(for: ordered[index])
            wm.bottomPane.activeTab?.hasUnreadNotification = true
            Logger.shared.debug("[projects] test-unread index=\(index) name=\(ordered[index].displayName)")
        }
        refreshUnreadProjects()
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
        temporary.append(project)
        persist()  // 一覧に新しい project が増えた = 永続状態が変わった
        setActive(project)
        return project
    }

    /// プロジェクトを閉じる（一覧から除去）。一時もピン留めも対象。
    /// 開いていた workspace は破棄する（shell プロセスも一緒に解放される）。
    func close(_ project: Project) {
        pinned.removeAll { $0.id == project.id }
        temporary.removeAll { $0.id == project.id }
        workspaces.removeValue(forKey: project.id)
        fileTrees.removeValue(forKey: project.id)
        previews.removeValue(forKey: project.id)
        fileIndexes.removeValue(forKey: project.id)
        if activeProject?.id == project.id {
            activeProject = allOrdered.first
        }
        persist()
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

    /// 各 workspace のタブ未読状態を走査して `unreadProjectIDs` を再計算する。
    /// タブの未読フラグが変わった箇所（BEL 受信・タブ選択・ペイン active 化・タブ閉じる）から呼ぶ。
    func refreshUnreadProjects() {
        var ids = Set<UUID>()
        for (projectID, wm) in workspaces where wm.hasUnreadTab {
            ids.insert(projectID)
        }
        if ids != unreadProjectIDs { unreadProjectIDs = ids }
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

    /// アクティブプロジェクトの中央ペインを ツリー ↔ プレビュー でトグル。
    /// Cmd+J（MRUKeyMonitor）と toolbar アイコンが共通で呼ぶ。
    func togglePreview() {
        guard let active = activeProject else { return }
        preview(for: active).toggle()
    }

    /// アクティブプロジェクトのファイルプレビュー状態（無ければ nil）。
    /// `MRUKeyMonitor` が Cmd+F / 検索バーのキー操作で参照する。
    var activePreview: FilePreviewModel? {
        guard let active = activeProject else { return nil }
        return preview(for: active)
    }

    /// アクティブプロジェクトのファイルツリーを再スキャン。
    /// Cmd+R（ツリーにフォーカスがあるとき）と toolbar の 🔄 ボタンが呼ぶ。
    func reloadActiveFileTree() {
        guard let active = activeProject else { return }
        fileTree(for: active).reload()
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
        // 閉じたら ignored トグルは OFF に戻す（次回 Cmd+P で常に OFF から始まる）。
        // OFF→OFF は didSet の比較で no-op になるので無駄な rebuild は走らない。
        if let active = activeProject {
            fileIndex(for: active).includeIgnored = false
        }
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

    /// Cmd+P で現在選択中のエントリの相対パス（無ければ nil）。Cmd+C コピー用。
    func quickSearchSelectedPath() -> String? {
        guard let active = activeProject else { return nil }
        let results = fileIndex(for: active).search(quickSearchQuery)
        guard results.indices.contains(quickSearchSelection) else { return nil }
        return results[quickSearchSelection].relativePath
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

    /// Cmd+Shift+F で現在選択中のヒットの相対パス（無ければ nil）。Cmd+C コピー用。
    func fullSearchSelectedPath() -> String? {
        guard fullSearchHits.indices.contains(fullSearchSelection) else { return nil }
        return relativePath(of: fullSearchHits[fullSearchSelection].url)
    }

    /// active project ルートからの相対パス。配下でなければ絶対パスを返す。
    private func relativePath(of url: URL) -> String {
        guard let active = activeProject else { return url.path }
        let rootPath = active.path.standardizedFileURL.path
        let abs = url.standardizedFileURL.path
        if abs == rootPath { return "." }
        if abs.hasPrefix(rootPath + "/") { return String(abs.dropFirst(rootPath.count + 1)) }
        return abs
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

    // MARK: - メタ情報の編集（名前・色）

    /// プロジェクトの表示名と色をまとめて更新する。
    /// `displayName` が空白のみの場合は path の lastPathComponent にフォールバック。
    func update(_ project: Project, displayName: String, colorKey: String?) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? project.path.lastPathComponent : trimmed

        let apply: (inout Project) -> Void = { p in
            p.displayName = resolvedName
            p.colorKey = colorKey
        }

        if let idx = pinned.firstIndex(where: { $0.id == project.id }) {
            apply(&pinned[idx])
            syncActive(to: pinned[idx])
            persist()
            return
        }
        if let idx = temporary.firstIndex(where: { $0.id == project.id }) {
            apply(&temporary[idx])
            syncActive(to: temporary[idx])
            persist()
        }
    }

    /// 配列内の project を更新したとき、それが現在 active なら `activeProject` も同じ値に揃える。
    private func syncActive(to project: Project) {
        if activeProject?.id == project.id { activeProject = project }
    }

    // MARK: - アクティブ切替

    /// プロジェクトを active にする。永続状態（projects.json）は変えない
    /// ＝ プロジェクト切替のたびに JSON を書く / backup を rotate するのをやめた。
    /// `lastOpenedAt` は現状の仕様（再起動で active を復元しない・temporary は手動順・MRU は別管理）
    /// ではほぼ使われないので、切替では更新しない。
    func setActive(_ project: Project) {
        // パスが消えている / マウント未接続なら開かない（要件 2: クリックしても開けない）。
        // ここで弾くことで、存在しない cwd で shell を起動しに行く workspace(for:) を呼ばない。
        if project.isMissing {
            ErrorBus.shared.notify("プロジェクトのパスが見つかりません: \(project.path.path)")
            return
        }
        let didSwitch = activeProject?.id != project.id
        activeProject = project
        // 初回 active 時に workspace を作る（=shell 起動）。2 回目以降は既存を再利用。
        let ws = workspace(for: project)
        // プロジェクトを開いたら、いま表示されるタブ（active pane の active tab）の未読はクリア。
        // 他ペイン・他タブに未読が残っていればサイドバーのリングは残る（要件 5）。
        ws.activePane.activeTab?.hasUnreadNotification = false
        refreshUnreadProjects()
        // 実際にプロジェクトが切り替わった瞬間に MRU 確定（要件通り）。
        if didSwitch { pushMRU(project.id) }
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

    // MARK: - ドラッグ並び替え

    /// ドロップ先の位置指定。
    enum DropPosition: Equatable {
        /// 指定 ID の前に挿入
        case beforeProject(UUID)
        /// 指定 ID の後ろに挿入
        case afterProject(UUID)
        /// pinned セクションの末尾に追加（必要なら自動で pin する）
        case endOfPinned
        /// temporary セクションの末尾に追加（必要なら自動で unpin する）
        case endOfTemporary
    }

    /// プロジェクトを別の位置に移動する。pinned ↔ temporary を跨いだ場合は
    /// `isPinned` を自動更新し、配列間で付け替える。
    /// 自分自身への drop は no-op。
    func move(_ sourceID: UUID, to position: DropPosition) {
        // 自分の前 / 後ろに drop した場合は no-op
        switch position {
        case .beforeProject(let target), .afterProject(let target):
            if target == sourceID { return }
        case .endOfPinned, .endOfTemporary:
            break
        }

        // 一旦取り出す
        var moved: Project
        if let idx = pinned.firstIndex(where: { $0.id == sourceID }) {
            moved = pinned.remove(at: idx)
        } else if let idx = temporary.firstIndex(where: { $0.id == sourceID }) {
            moved = temporary.remove(at: idx)
        } else {
            return
        }

        // 挿入先を決めて反映（途中で target が消えた場合の保険として元のセクション末尾へ append）
        switch position {
        case .beforeProject(let targetID):
            if let idx = pinned.firstIndex(where: { $0.id == targetID }) {
                moved.isPinned = true
                pinned.insert(moved, at: idx)
            } else if let idx = temporary.firstIndex(where: { $0.id == targetID }) {
                moved.isPinned = false
                temporary.insert(moved, at: idx)
            } else {
                appendBack(moved)
                return
            }
        case .afterProject(let targetID):
            if let idx = pinned.firstIndex(where: { $0.id == targetID }) {
                moved.isPinned = true
                pinned.insert(moved, at: idx + 1)
            } else if let idx = temporary.firstIndex(where: { $0.id == targetID }) {
                moved.isPinned = false
                temporary.insert(moved, at: idx + 1)
            } else {
                appendBack(moved)
                return
            }
        case .endOfPinned:
            moved.isPinned = true
            pinned.append(moved)
        case .endOfTemporary:
            moved.isPinned = false
            temporary.append(moved)
        }

        if activeProject?.id == sourceID { activeProject = moved }
        persist()
    }

    private func appendBack(_ project: Project) {
        if project.isPinned {
            pinned.append(project)
        } else {
            temporary.append(project)
        }
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
            persist()
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
        store.save(pinned + temporary)
    }
}
