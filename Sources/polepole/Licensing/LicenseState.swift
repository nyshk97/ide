import Foundation

/// アプリ全体のライセンス状態。
///
/// 状態遷移:
/// - 初回起動: TrialManager が install date を書く → `.trial(daysLeft: 14)`
/// - 通常起動: install date から経過日数 elapsed を見て `.trial(daysLeft: 14 - elapsed)`
/// - elapsed >= 14: `.trialExpired`
/// - activate 成功 (Phase 6): `.activated(token: ...)`
/// - 連続 30 日 verify 失敗 (Phase 6): `.deactivated`
///
/// `.trialExpired` / `.deactivated` のとき、`PaywallView` が全 view を覆って機能を停止する
/// (要件 6 / 8.3)。
enum LicenseState: Equatable, Sendable {
    case trial(daysLeft: Int)
    case activated(token: ActivationToken)
    case trialExpired
    case deactivated

    /// PaywallView を出して機能を停止すべきか。
    var isLocked: Bool {
        switch self {
        case .trialExpired, .deactivated: return true
        case .trial, .activated: return false
        }
    }
}

/// アクティベーションサーバ (Cloudflare Workers `/v1/license/{activate,verify}`) から
/// 受け取る EdDSA 署名済みトークン。
///
/// 形式: `<base64url(payload_json)>.<base64url(signature)>`
/// payload は TokenPayload (backend/src/lib/signing.ts と同 shape)。
///
/// 保存: Keychain (Service=Bundle ID, Account=`activation-token`) に raw 文字列を書く。
/// 検証 (Phase 6): Resources/License/license-pubkey.pem の Ed25519 公開鍵で
/// CryptoKit.Curve25519.Signing.PublicKey.isValidSignature を使う。
struct ActivationToken: Equatable, Sendable, Codable {
    /// `<base64url(payload)>.<base64url(signature)>` の raw 文字列。
    /// Keychain に保存するのはこれそのもの。
    let raw: String
    /// decode 済み payload。サーバから受け取った時点で 1 度パースし、毎起動の使用時は
    /// raw を再パースする (Phase 6 で `parse` ヘルパーを追加)。
    let payload: TokenPayload

    struct TokenPayload: Equatable, Sendable, Codable {
        let key: String
        let email: String
        let deviceHash: String
        let licenseStatus: String
        let issuedAt: Int64
        let maxOfflineDays: Int

        enum CodingKeys: String, CodingKey {
            case key
            case email
            case deviceHash = "device_hash"
            case licenseStatus = "license_status"
            case issuedAt = "issued_at"
            case maxOfflineDays = "max_offline_days"
        }
    }
}
