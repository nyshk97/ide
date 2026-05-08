import Foundation

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()

    /// タブバー表示名。step6 以降で `ghostty_action_set_title` 連動を入れる予定。
    @Published var title: String

    init(title: String) {
        self.title = title
    }
}
