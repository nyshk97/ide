import Foundation
import SwiftUI

/// Diff overlay 用の状態保持。`DiffOverlayView.onAppear` で `load(project:)` を呼ぶ。
@MainActor
final class DiffViewModel: ObservableObject {
    @Published private(set) var files: [FileDiff] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// 最後にロードしたプロジェクト。reload 時に再利用する。
    private var lastProject: Project?

    func load(project: Project) {
        lastProject = project
        let path = project.path
        isLoading = true
        errorMessage = nil

        Task.detached { [weak self] in
            let diffs = DiffService.fetchDiffs(repoPath: path)
            await MainActor.run {
                guard let self else { return }
                self.files = diffs
                self.isLoading = false
            }
        }
    }

    func reload() {
        guard let lastProject else { return }
        load(project: lastProject)
    }

    /// overlay を閉じたとき。次回開いたときは再取得する想定なのでメモリ解放する。
    func clear() {
        files = []
        isLoading = false
        errorMessage = nil
        lastProject = nil
    }
}
