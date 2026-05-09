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

    /// 現在アクティブなプロジェクト。サイドバーでのハイライトと（step4 以降の）ターミナル選択に使う。
    @Published private(set) var activeProject: Project?

    private let store: ProjectsStore

    private init(store: ProjectsStore = .shared) {
        self.store = store
        load()
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
    func close(_ project: Project) {
        let wasPinned = project.isPinned
        pinned.removeAll { $0.id == project.id }
        temporary.removeAll { $0.id == project.id }
        if activeProject?.id == project.id {
            activeProject = allOrdered.first
        }
        if wasPinned { persist() }
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
