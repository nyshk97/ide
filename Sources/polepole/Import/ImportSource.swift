import Foundation

/// プロジェクトの発見 source 共通プロトコル。
///
/// - `discover()` は非同期で 1 回呼ばれる。長くなる scan も内部で I/O を切り上げて返す責務を持つ。
/// - 該当ファイルが無い / 未インストールの場合は空配列を返す（エラー UI は出さない）。
protocol ImportSource: Sendable {
    /// 例: "cmux" / "ghq" / "tmuxinator" / "vscode" / "cursor"。
    /// `DiscoveredProject.sourceId` と一致させる。バッジ表示と filter chip の key に使う。
    var id: String { get }
    /// バッジに表示する短い英字（"cmux" / "ghq" / "tmuxinator" / "VS Code" / "Cursor"）。
    var displayName: String { get }
    func discover() async -> [DiscoveredProject]
}
