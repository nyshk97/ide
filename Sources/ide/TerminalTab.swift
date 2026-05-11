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

    /// AI 完了などで未読通知が立っている状態。アクティブ化で自動クリアする。
    @Published var hasUnreadNotification: Bool = false

    /// AI ツール（claude / codex）が `OSC 9;4` のプログレスで「作業中」を表明していて、
    /// まだ REMOVE で消されていない状態。`作業中 → REMOVE` の遷移だけを「ターン完了」とみなし、
    /// 起動直後の空 REMOVE 等での誤検知を防ぐためのフラグ。
    var aiTurnInProgress: Bool = false

    /// foreground プロセスを定期 polling して識別した結果。タブのアイコン表示に使う。
    @Published var foregroundProgram: ForegroundProgram = .shell

    enum ForegroundProgram: Equatable {
        case shell           // シェルだけ動いている（バッジ無し）
        case claude
        case codex
        case other(String)   // 上記以外（バッジ無しでもよいが将来 hook 可能）
    }

    enum Lifecycle: Equatable {
        case alive
        case exited(code: UInt32)
    }

    /// 起動時 cwd。プロジェクトのルートを渡す想定。nil なら $HOME。
    let cwd: URL?

    init(title: String, cwd: URL? = nil) {
        self.title = title
        self.cwd = cwd
    }

    func restart() {
        lifecycle = .alive
        generation += 1
    }
}
