import Foundation

/// Ctrl+M で表示する MRU 切替オーバーレイの状態。
struct MRUOverlayState: Equatable {
    /// 表示する候補（MRU 順）。
    var candidates: [Project]
    /// 現在ハイライト中のインデックス。
    var selection: Int
}
