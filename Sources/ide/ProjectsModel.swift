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

    private let store: ProjectsStore

    private init(store: ProjectsStore = .shared) {
        self.store = store
        load()
        applyTestAutoActivate()
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
        activeProject = updated
        // 初回 active 時に workspace を作る（=shell 起動）。2 回目以降は既存を再利用。
        _ = workspace(for: updated)
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
