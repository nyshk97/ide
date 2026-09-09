import Combine
import SwiftUI

/// プロジェクト一覧と active project を保持する singleton。
///
/// - pinned / temporary 両方を `~/Library/Application Support/polepole/projects.json` に永続化
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

    /// アクティブプロジェクトのプレビューペインを開いているか（4 カラムレイアウトでの
    /// プレビューペイン collapse 判定に使う）。`RootLayoutView` がこれを観察して
    /// NSSplitViewItem.isCollapsed に反映する。
    ///
    /// `activeProject` 切替時に新 active の `preview.$currentURL` を購読し直す。
    /// 古い購読は `activePreviewCancellable` の差し替えで自動 cancel される。
    @Published private(set) var activePreviewVisible: Bool = false
    private var activePreviewCancellable: AnyCancellable?
    private var activeProjectCancellable: AnyCancellable?

    /// 左サイドバー（プロジェクト一覧）を折りたたんでいるか。グローバル状態。
    /// UserDefaults に永続化する。`RootLayoutView` がこれを観察して collapse する。
    @Published var sidebarCollapsed: Bool = false {
        didSet {
            UserDefaults.standard.set(sidebarCollapsed, forKey: "polepole.sidebarCollapsed")
        }
    }

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

    /// Cmd+D で表示する diff オーバーレイの状態。
    @Published var diffOverlayVisible: Bool = false
    /// overlay 表示中だけ生きている diff データ。閉じたら `clear()` で空にする。
    let diffViewModel = DiffViewModel()

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
        // サイドバー折畳状態を UserDefaults から復元
        self.sidebarCollapsed = UserDefaults.standard.bool(forKey: "polepole.sidebarCollapsed")
        // activeProject 切替に追従して active な FilePreviewModel.currentURL を購読し直す。
        // 購読張り替え直後の初期値も同期するので、新 active が currentURL を既に持っていれば
        // activePreviewVisible は即 true になる。
        activeProjectCancellable = $activeProject
            .sink { [weak self] project in
                self?.rewireActivePreviewSubscription(to: project)
            }
        // 未読フラグ → アクティブ化の順。こうしておくと AUTO_ACTIVATE と UNREAD_INDICES を
        // 同じプロジェクトに向けたとき「アクティブ化でそのプロジェクトの表示タブの未読が消える」
        // 挙動も検証できる。
        applyTestUnreadIndices()
        applyTestAutoActivate()
        autoActivateLastOpenedProject()
        applyTestAutoPreview()
        #if DEBUG
        TestEventInjector.installIfRequested()
        #endif
        applyTestSidebarCollapsed()
    }

    /// 起動時に `lastOpenedAt` が最新のプロジェクトを自動で active にする。
    /// パスが消えていたら次に新しい有効なプロジェクトを順に試し、全部無効なら未選択のまま。
    /// `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` で既に active が決まっている場合は何もしない。
    private func autoActivateLastOpenedProject() {
        guard activeProject == nil else { return }
        let candidates = allOrdered.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        for candidate in candidates where !candidate.isMissing {
            setActive(candidate)
            Logger.shared.debug("[projects] auto-activate-last-opened name=\(candidate.displayName)")
            return
        }
    }

    /// activeProject 切替に追従して新 active の preview.$currentURL を購読し直す。
    /// 古い購読は `activePreviewCancellable` の差し替えで自動 cancel される。
    /// 購読張り替え直後の初期値も `activePreviewVisible` / `fileTree.selectedURL` に書き込む
    /// （sink だけだと初期値が漏れる）。
    ///
    /// `fileTree.selectedURL` への同期は preview navigation（← / →、markdown リンク、
    /// Cmd+P、Cmd+Shift+F 等）すべての経路をここで一元的に拾うため。close（url == nil）の
    /// ときは `selectedURL` を維持する（FileTreeModel.selectedURL の「閉じても残す」仕様）。
    private func rewireActivePreviewSubscription(to project: Project?) {
        guard let project else {
            activePreviewCancellable = nil
            activePreviewVisible = false
            return
        }
        let preview = preview(for: project)
        let tree = fileTree(for: project)
        // 初期値を即反映
        activePreviewVisible = (preview.currentURL != nil)
        if let url = preview.currentURL {
            tree.selectedURL = url
        }
        // 以降の変化を購読
        activePreviewCancellable = preview.$currentURL
            .sink { [weak self] url in
                self?.activePreviewVisible = (url != nil)
                if let url {
                    tree.selectedURL = url
                }
            }
    }

    private func load() {
        let restored = store.load()
        // pinned / temporary とも保存時の順序をそのまま復元する。
        // temporary はかつて lastOpenedAt 降順で並べていたが、ドラッグ並び替えを導入した
        // タイミングで「ユーザーが手で決めた順を尊重」する方針に変更した（mruStack は別管理）。
        self.pinned = restored.filter { $0.isPinned }
        self.temporary = restored.filter { !$0.isPinned }
    }

    /// `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` 環境変数が設定されている場合、起動時に
    /// 指定インデックスのプロジェクト（allOrdered = pinned + temporary）をアクティブにする。
    /// VERIFY 用デバッグ機能。通常は要件通り「再起動時は active を復元しない」挙動。
    private func applyTestAutoActivate() {
        guard let envValue = ProcessInfo.processInfo.environment["POLEPOLE_TEST_AUTO_ACTIVATE_INDEX"],
              let index = Int(envValue) else { return }
        let ordered = allOrdered
        guard ordered.indices.contains(index) else { return }
        let target = ordered[index]
        setActive(target)
        Logger.shared.debug("[projects] test-auto-activate index=\(index) name=\(target.displayName)")
    }

    /// `POLEPOLE_TEST_AUTO_PREVIEW` 環境変数が active project からの相対パスを指していたら
    /// その file を preview に開く。VERIFY 用デバッグ機能。
    private func applyTestAutoPreview() {
        let env = ProcessInfo.processInfo.environment

        if let relPath = env["POLEPOLE_TEST_AUTO_PREVIEW"],
           let active = activeProject {
            let target = active.path.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: target.path) {
                preview(for: active).open(target)
                Logger.shared.debug("[projects] test-auto-preview \(relPath)")
            }
        }

        if let query = env["POLEPOLE_TEST_PREVIEW_FIND"], let active = activeProject {
            let p = preview(for: active)
            if p.currentURL != nil {
                p.findQuery = query
                p.showFindBar()
                Logger.shared.debug("[projects] test-preview-find \(query)")
            }
        }

        if let query = env["POLEPOLE_TEST_AUTO_FULLSEARCH"] {
            openFullSearch()
            fullSearchQuery = query
            runFullSearch()
        }

        if let query = env["POLEPOLE_TEST_AUTO_QUICKSEARCH"] {
            openQuickSearch()
            quickSearchQuery = query
            Logger.shared.debug("[projects] test-auto-quicksearch \(query)")
        }

        if env["POLEPOLE_TEST_AUTO_OPEN_DIFF"] != nil, activeProject != nil {
            openDiffOverlay()
            Logger.shared.debug("[projects] test-auto-open-diff")
        }

        if let toast = env["POLEPOLE_TEST_TOAST"] {
            // ErrorBus は MainActor、init からの呼び出しは MainActor 隔離なので OK
            ErrorBus.shared.notify(toast, kind: .error)
        }

        // FSEvents → FileIndex 自動更新の検証。`POLEPOLE_TEST_AUTO_FSEVENTS_PROBE=<filename>`
        // を渡すと、active project に当該ファイルを touch → 数秒待って FileIndex.search() の
        // hit 数を Logger に出す。再起動なしで FSEvents 経路そのものを検証する手段。
        if let filename = env["POLEPOLE_TEST_AUTO_FSEVENTS_PROBE"], let active = activeProject {
            runFsEventsProbe(filename: filename, project: active)
        }
    }

    /// FSEvents probe: active project に `<filename>` を作成し、
    /// debounce + rebuild の時間を待ってから FileIndex.search() の結果を log に出す。
    /// VERIFY での自動検証用。
    private func runFsEventsProbe(filename: String, project: Project) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // FileIndex を **先に** 作成して watcher を立ち上げる。
            // この呼び出しが lazy 生成のトリガなので、これより前に touch しても
            // watcher が居らず event を取りこぼす。
            let index = self.fileIndex(for: project)
            Logger.shared.info("[fsevents-probe] FileIndex created, waiting for initial rebuild")
            // 初回 rebuild (Task.detached + scan) が完了するまで polling 待ち
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !index.isBuilding && index.entries.count > 0 { break }
            }
            Logger.shared.info("[fsevents-probe] initial rebuild done entries=\(index.entries.count)")

            let probeURL = project.path.appendingPathComponent(filename)
            do {
                try "fsevents probe".write(to: probeURL, atomically: true, encoding: .utf8)
                Logger.shared.info("[fsevents-probe] created \(probeURL.path)")
            } catch {
                Logger.shared.error("[fsevents-probe] failed to create: \(error)")
                return
            }
            // FSEvents (1.0s latency) + debounce (0.5s) + minRebuildInterval (2s) + rebuild を考慮
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let hits = index.search(filename).count
            Logger.shared.info("[fsevents-probe] search(\(filename)) hits=\(hits)")

            // 削除側の検証も同 probe で実施
            try? FileManager.default.removeItem(at: probeURL)
            Logger.shared.info("[fsevents-probe] removed \(probeURL.path)")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let hitsAfterDelete = index.search(filename).count
            Logger.shared.info("[fsevents-probe] after-delete search(\(filename)) hits=\(hitsAfterDelete)")
        }
    }

    /// `POLEPOLE_TEST_SIDEBAR_COLLAPSED=1` が立っていたら起動時にサイドバー折畳状態に。
    /// VERIFY 用デバッグ機能。
    private func applyTestSidebarCollapsed() {
        guard let v = ProcessInfo.processInfo.environment["POLEPOLE_TEST_SIDEBAR_COLLAPSED"],
              v == "1" || v.lowercased() == "true" else { return }
        sidebarCollapsed = true
        Logger.shared.debug("[projects] test-sidebar-collapsed")
    }

    /// `POLEPOLE_TEST_UNREAD_INDICES=0,2` のように指定すると、allOrdered の該当インデックスの
    /// プロジェクトの workspace を作成し、下ペインのカレントタブに未読通知を立てる。
    /// サイドバーのリング表示の VERIFY 用デバッグ機能。
    private func applyTestUnreadIndices() {
        guard let raw = ProcessInfo.processInfo.environment["POLEPOLE_TEST_UNREAD_INDICES"] else { return }
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
        fullSearchVisible = false
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

    /// Cmd+P で現在選択中のエントリの相対パス（無ければ nil）。Cmd+C コピー用。
    func quickSearchSelectedPath() -> String? {
        guard let active = activeProject else { return nil }
        let results = fileIndex(for: active).search(quickSearchQuery)
        guard results.indices.contains(quickSearchSelection) else { return nil }
        return results[quickSearchSelection].relativePath
    }

    /// Enter で現在選択中のエントリを開いてオーバーレイを閉じる。
    func quickSearchConfirm() {
        guard let active = activeProject else { return }
        let results = fileIndex(for: active).search(quickSearchQuery)
        guard results.indices.contains(quickSearchSelection) else { return }
        quickSearchSelect(results[quickSearchSelection])
    }

    // MARK: - Cmd+Shift+F 全文検索

    func openFullSearch() {
        guard activeProject != nil else { return }
        quickSearchVisible = false
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
                guard let self = self else { return }
                // 検索中にクエリが書き換わっていたら古い結果は破棄。
                // FullSearchView 側の onChange(of: query) で hits を空にしているので、
                // ここで上書きすると消したはずの古い結果が復活してしまう。
                if self.fullSearchQuery == q {
                    self.fullSearchHits = result
                }
                self.fullSearchInProgress = false
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

    // MARK: - Cmd+D Diff オーバーレイ

    /// active project がなければ何もしない（ボタンも本来 disabled だがガード）。
    /// 開いた瞬間に `git diff` を走らせる（先読みはしない方針）。
    func openDiffOverlay() {
        guard let active = activeProject else { return }
        diffViewModel.load(project: active)
        diffOverlayVisible = true
    }

    func closeDiffOverlay() {
        diffOverlayVisible = false
        // 閉じたタイミングでメモリ解放。次に開いたとき取り直す。
        diffViewModel.clear()
    }

    /// Cmd+D 押下時のトグル。MRUKeyMonitor から呼ばれる。
    func toggleDiffOverlay() {
        if diffOverlayVisible {
            closeDiffOverlay()
        } else {
            openDiffOverlay()
        }
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

    /// プロジェクトの `paneLayout` を更新する。`WorkspaceModel.paneLayout.didSet` から呼ばれる。
    /// `update(_:displayName:colorKey:)` と同じパターン: apply → pinned/temporary 更新 → syncActive → persist。
    func updatePaneLayout(projectID: UUID, layout: PaneLayout) {
        let apply: (inout Project) -> Void = { p in
            p.paneLayout = layout
        }
        if let idx = pinned.firstIndex(where: { $0.id == projectID }) {
            apply(&pinned[idx])
            syncActive(to: pinned[idx])
            persist()
            return
        }
        if let idx = temporary.firstIndex(where: { $0.id == projectID }) {
            apply(&temporary[idx])
            syncActive(to: temporary[idx])
            persist()
        }
    }

    // MARK: - アクティブ切替

    /// プロジェクトを active にする。
    /// 切り替えが発生したときだけ `lastOpenedAt` を更新して永続化する
    /// （起動時の「最後に開いたプロジェクトを自動で開く」判定に使う）。
    func setActive(_ project: Project) {
        // パスが消えている / マウント未接続なら開かない（要件 2: クリックしても開けない）。
        // ここで弾くことで、存在しない cwd で shell を起動しに行く workspace(for:) を呼ばない。
        if project.isMissing {
            ErrorBus.shared.notify("Project path not found: \(project.path.path)")
            return
        }
        let didSwitch = activeProject?.id != project.id

        // pinned / temporary 配列内の lastOpenedAt を更新して、起動時の自動選択判定に反映させる。
        // 切替時のみ更新（同じプロジェクトを setActive し直しても書き込まない）。
        var resolved = project
        if didSwitch {
            let now = Date()
            if let idx = pinned.firstIndex(where: { $0.id == project.id }) {
                pinned[idx].lastOpenedAt = now
                resolved = pinned[idx]
            } else if let idx = temporary.firstIndex(where: { $0.id == project.id }) {
                temporary[idx].lastOpenedAt = now
                resolved = temporary[idx]
            }
        }

        activeProject = resolved
        // 初回 active 時に workspace を作る（=shell 起動）。2 回目以降は既存を再利用。
        let ws = workspace(for: resolved)
        // プロジェクトを開いたら、いま表示されるタブ（active pane の active tab）の未読はクリア。
        // 他ペイン・他タブに未読が残っていればサイドバーのリングは残る（要件 5）。
        ws.activePane.activeTab?.hasUnreadNotification = false
        refreshUnreadProjects()
        // 実際にプロジェクトが切り替わった瞬間に MRU 確定（要件通り）。
        if didSwitch {
            pushMRU(resolved.id)
            persist()
        }
    }

    // MARK: - MRU

    /// MRU スタックの先頭にプロジェクト ID を移動（重複は除去、上限 5 件）。
    private func pushMRU(_ id: UUID) {
        mruStack.removeAll { $0 == id }
        mruStack.insert(id, at: 0)
        if mruStack.count > mruLimit { mruStack.removeLast(mruStack.count - mruLimit) }
    }

    /// オーバーレイ用の候補。直近に使った最大 `mruLimit` 件だけ（close 済みは除外）。
    /// 並び順は「このセッションで切り替えた順（MRU）」を最優先し、残り枠は `lastOpenedAt` 降順で埋める。
    func mruCandidates() -> [Project] {
        let allById: [UUID: Project] = Dictionary(uniqueKeysWithValues: allOrdered.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result: [Project] = []
        // このセッションで実際に切り替えた順（MRU）を最優先。
        for id in mruStack {
            if let p = allById[id], !seen.contains(id) {
                result.append(p)
                seen.insert(id)
            }
        }
        // 残り枠は lastOpenedAt が新しい順に埋める（再起動直後で mruStack が薄くても「直近使った」順になる）。
        for p in allOrdered.sorted(by: { $0.lastOpenedAt > $1.lastOpenedAt }) where !seen.contains(p.id) {
            result.append(p)
            seen.insert(p.id)
        }
        return Array(result.prefix(mruLimit))
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

    /// 同一プロジェクトを返す（あれば）。
    /// symlink 経由のパスと実体パスを同一視するため、`PathNormalizer.canonicalKey` で比較する。
    /// canonicalize できないパス（存在しない・空）が来た場合は標準化済み path での厳密一致にフォールバック。
    func project(at path: URL) -> Project? {
        if let targetKey = PathNormalizer.canonicalKey(path) {
            return allOrdered.first { existing in
                PathNormalizer.canonicalKey(existing.path) == targetKey
            }
        }
        let fallback = path.standardizedFileURL.path
        return allOrdered.first { $0.path.standardizedFileURL.path == fallback }
    }

    // MARK: - 一括インポート

    /// 複数の発見されたプロジェクトを一括で追加する。
    /// `ImportSheet` / Settings の Import タブから呼ばれる唯一の入口で、
    /// `pinned` / `temporary` への振り分け・dedup・persist・初回 active 化までここで完結させる。
    ///
    /// - dedup は `PathNormalizer.canonicalKey` ベース。既に登録済みの canonical key と被るものは黙ってスキップ。
    /// - 保存パスは `payload.preferredPath` をそのまま使う（symlink 経由運用を尊重）。
    /// - `payload.isPinned == true` は pinned 末尾、false は temporary 末尾に末尾追加。同 phase 内の順序は引数順を保つ。
    /// - 既に何かの project が active なら active は変えない。`activeProject == nil` の場合のみ最初の追加分を active にする。
    /// - 返り値は実際に追加された Project 配列（スキップ分を除く）。
    @discardableResult
    func importProjects(_ payloads: [ImportPayload]) -> [Project] {
        guard !payloads.isEmpty else { return [] }

        // 既存 + 同一バッチ内の重複も避けるための canonical key 集合
        var seenKeys = Set<String>()
        for existing in allOrdered {
            if let key = PathNormalizer.canonicalKey(existing.path) {
                seenKeys.insert(key)
            }
        }

        var added: [Project] = []
        for payload in payloads {
            let url = URL(fileURLWithPath: payload.preferredPath)
            let key = PathNormalizer.canonicalKey(payload.preferredPath) ?? url.standardizedFileURL.path
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)

            let project = Project(
                path: url,
                displayName: payload.displayName,
                isPinned: payload.isPinned
            )
            if payload.isPinned {
                pinned.append(project)
            } else {
                temporary.append(project)
            }
            added.append(project)
        }

        guard !added.isEmpty else { return [] }
        persist()
        // 既に active なものがあればそれを尊重。何も active でなければ最初の追加分を active 化。
        if activeProject == nil, let first = added.first {
            setActive(first)
        }
        Logger.shared.info("[import] imported \(added.count) project(s) (skipped \(payloads.count - added.count))")
        return added
    }

    // MARK: - 永続化

    private func persist() {
        store.save(pinned + temporary)
    }
}
