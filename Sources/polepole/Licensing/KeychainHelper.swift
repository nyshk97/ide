import Foundation
import Security

/// Keychain への薄いラッパー。
///
/// Service は Bundle ID（`local.d0ne1s.polepole` / `local.d0ne1s.polepole.dev`）を使い、
/// Account ごとに 1 つの文字列を保存する。Release と Debug は Bundle ID が違うので
/// keychain item も自動で分離される（Application Support と同じ分離戦略）。
///
/// 用途:
/// - `trial-install-date`: トライアル開始日（ISO8601）
/// - `activation-token`: アクティベーション署名トークン（Phase 6 で本格運用）
/// - `last-observed-now`: 時計巻き戻し対策の monotonic clock（Phase 6）
enum KeychainHelper {
    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case dataEncodingFailed
    }

    /// Service 名は Bundle ID。テスト等で Bundle が読めないことは想定しない
    /// （PolePole は常にアプリ bundle 内で動く）。
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "local.d0ne1s.polepole"
    }

    /// 値を保存する。既存があれば update、無ければ add。
    static func set(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// 値を読む。存在しなければ nil（エラーではない）。
    static func get(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// 削除する。存在しなくても成功扱い。
    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
