import AppKit
import Foundation

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()

    /// タブバー表示名。後の step で `ghostty_action_set_title` 連動を入れる予定。
    @Published var title: String

    /// シェルの生死状態。exit 時は overlay で exit code を表示する。
    @Published var lifecycle: Lifecycle = .alive

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

    /// このタブが所有する NSView（Phase 2 リファクタ）。
    /// SwiftUI の view tree 変動と無関係に Ghostty surface を生かしておくため、
    /// `TerminalTab` が strong で抱える。`SwiftUI 側 (GhosttyTerminalView)` は Container NSView だけを
    /// SwiftUI に見せ、`updateNSView` で `realNSView` を `addSubview` する設計。
    /// ペイン跨ぎ移動でも `addSubview` の AppKit 仕様で旧 superview から自動的に外れて
    /// 新 superview に付け替わる → NSView 本体は一度も destroy されない → surface 生存 → shell 死なない。
    let realNSView: GhosttyTerminalNSView

    init(title: String, cwd: URL? = nil) {
        self.title = title
        self.cwd = cwd
        self.realNSView = GhosttyTerminalNSView(frame: .zero)
        // 全 stored property の初期化後に self を逆参照させる
        self.realNSView.tab = self
    }

    /// `TerminalTab` が捨てられたタイミングで Ghostty surface を解放する。
    /// NSView 側の `deinit` からは `ghostty_surface_free` を外したので、ここでやる責務がある。
    /// `deinit` は nonisolated だが、TerminalTab の lifecycle は MainActor 文脈で操作されるため
    /// `MainActor.assumeIsolated` で MainActor を仮定して呼ぶ。
    deinit {
        MainActor.assumeIsolated {
            realNSView.releaseSurface()
        }
    }

    /// exit overlay の「再起動」ボタンから呼ばれる。surface を作り直して overlay を消す。
    /// 新設計では SwiftUI 経由の view 再生成は不要（同じ `realNSView` 内で surface だけ入れ替える）。
    func restart() {
        realNSView.restartSurface()
        lifecycle = .alive
    }
}
