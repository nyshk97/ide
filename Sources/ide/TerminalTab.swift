import Foundation

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()

    /// タブバー表示名。後の step で `ghostty_action_set_title` 連動を入れる予定。
    @Published var title: String

    /// シェルの生死状態。exit 時は overlay で exit code を表示する。
    @Published var lifecycle: Lifecycle = .alive

    /// `restart()` で increment。SwiftUI 側の `.id()` に混ぜることで view 再生成を起こす。
    @Published var generation: Int = 0

    /// BEL 受信などで未読通知が立っている状態。アクティブ化で自動クリアする。
    @Published var hasUnreadNotification: Bool = false

    enum Lifecycle: Equatable {
        case alive
        case exited(code: UInt32)
    }

    init(title: String) {
        self.title = title
    }

    func restart() {
        lifecycle = .alive
        generation += 1
    }
}
