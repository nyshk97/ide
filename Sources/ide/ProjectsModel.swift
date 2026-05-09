import SwiftUI

/// プロジェクト一覧と active project を保持する singleton。
///
/// step2 はインメモリのみ（永続化は step3）。
/// active 切替時のターミナル切替は step4 で実装する。
@MainActor
final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    /// ピン留めプロジェクト。手動並び替えされうる順序で保持。
    @Published private(set) var pinned: [Project] = []

    /// 一時プロジェクト。MRU 順（先頭が最近開いた）。
    @Published private(set) var temporary: [Project] = []

    /// 現在アクティブなプロジェクト。サイドバーでのハイライトと（step4 以降の）ターミナル選択に使う。
    @Published private(set) var activeProject: Project?

    private init() {}

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
        pinned.removeAll { $0.id == project.id }
        temporary.removeAll { $0.id == project.id }
        if activeProject?.id == project.id {
            activeProject = allOrdered.first
        }
    }

    // MARK: - ピン留め切替

    func togglePin(_ project: Project) {
        if project.isPinned {
            unpin(project)
        } else {
            pin(project)
        }
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
        } else if let idx = temporary.firstIndex(where: { $0.id == project.id }) {
            temporary.remove(at: idx)
            temporary.insert(updated, at: 0)
        }
        activeProject = updated
    }

    // MARK: - 検索

    /// 同一の絶対パスを持つプロジェクトを返す（あれば）。
    func project(at path: URL) -> Project? {
        let target = path.standardizedFileURL.path
        return allOrdered.first { $0.path.standardizedFileURL.path == target }
    }
}
