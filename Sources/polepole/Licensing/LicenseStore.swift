import Foundation
import SwiftUI

/// アプリ全体のライセンス状態 (singleton)。
///
/// 起動時に `TrialManager` から install date を読んで `LicenseState` を確定する。
/// Phase 5 ではトライアル経路のみ実装。Phase 6 で activate/verify/deactivate を実装し、
/// `.activated(token:)` 経路を有効化する。
///
/// `state.isLocked == true` のときに `PaywallView` が overlay として全 view を覆い、
/// 機能を停止する (要件 6 / 8.3)。
@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    @Published private(set) var state: LicenseState

    private init() {
        self.state = .trial(daysLeft: TrialManager.trialDurationDays)
        refreshFromDisk()
    }

    /// 起動時 / アプリ復帰時に Keychain / Application Support / (Phase 6) サーバから
    /// 状態を読み直す。Phase 5 ではトライアル経路のみ。
    func refreshFromDisk() {
        // TODO(Phase 6): Keychain の activation-token を読み、検証して .activated に遷移する
        let daysLeft = TrialManager.shared.daysRemaining()
        if daysLeft <= 0 {
            state = .trialExpired
        } else {
            state = .trial(daysLeft: daysLeft)
        }
        Logger.shared.info("[license] state = \(stateLabel(state))")
    }

    // MARK: - Phase 6 で実装する穴

    /// ユーザーが入力したキーとメアドでアクティベーションを試みる。
    /// Phase 5 では未実装 (UI からは disabled で見せる)。
    func activate(key: String, email: String) async {
        // TODO(Phase 6): LicenseClient.activate を呼び、レスポンスのトークンを Keychain に
        // 書いて .activated に遷移する
        Logger.shared.info("[license] activate stub: key=\(key.prefix(12))... email=\(email)")
    }

    /// このデバイスを deactivate する (Phase 6)。
    func deactivate() async {
        // TODO(Phase 6): LicenseClient.deactivate を呼び、Keychain のトークンを消す
        Logger.shared.info("[license] deactivate stub")
    }

    private func stateLabel(_ s: LicenseState) -> String {
        switch s {
        case .trial(let d): return "trial(\(d) days left)"
        case .activated: return "activated"
        case .trialExpired: return "trialExpired"
        case .deactivated: return "deactivated"
        }
    }
}
