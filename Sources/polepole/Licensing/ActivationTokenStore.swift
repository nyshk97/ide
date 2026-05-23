import Foundation

/// アクティベーション署名トークンの永続化担当。
///
/// TrialManager と同じ二重保存戦略:
/// - Keychain (Service = Bundle ID, Account = `activation-token`) に raw 文字列を書く
/// - `~/Library/Application Support/{polepole,polepole-dev}/token.json` にも書く
/// - 読み込みは Keychain 優先、無ければ token.json から、両方無ければ nil
/// - load() が片方しか見つけられないときは、もう片方に補完書きする
///
/// なぜ二重か:
/// - Keychain: 再 install しても残る (= デバイス紐付きで安心)
/// - token.json: Keychain Access から手で消されても (or 開発時に security delete) 復元できる
///
/// raw 文字列 (= base64url payload + "." + base64url signature) をそのまま保存し、
/// 起動時毎回 `TokenVerifier` で検証する。decode した payload は LicenseStore がメモリで持つ。
enum ActivationTokenStore {
    private static let keychainAccount = "activation-token"

    private static var tokenJsonURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("token.json")
    }

    private struct TokenFile: Codable {
        let token: String
    }

    /// トークンを読み出す。両方無ければ nil。片方しか無ければもう片方に補完書きする。
    static func load() -> String? {
        let fromKeychain = readKeychain()
        let fromFile = readFile()

        let resolved: String?
        switch (fromKeychain, fromFile) {
        case let (k?, f?):
            // 普通は両者一致するが、ズレたら Keychain を真とする (再 install 耐性が強いため)
            if k != f {
                Logger.shared.warn("[license] keychain vs token.json mismatch, using keychain")
                writeFile(k)
            }
            resolved = k
        case (let k?, nil):
            writeFile(k)
            resolved = k
        case (nil, let f?):
            writeKeychain(f)
            resolved = f
        case (nil, nil):
            resolved = nil
        }
        return resolved
    }

    /// トークンを Keychain と token.json の両方に書く。activate / verify 成功時に呼ぶ。
    static func save(_ token: String) {
        writeKeychain(token)
        writeFile(token)
    }

    /// 両方から消す。deactivate 時に呼ぶ。
    static func clear() {
        do {
            try KeychainHelper.delete(account: keychainAccount)
        } catch {
            Logger.shared.warn("[license] keychain delete failed: \(error)")
        }
        try? FileManager.default.removeItem(at: tokenJsonURL)
    }

    // MARK: - Private

    private static func readKeychain() -> String? {
        do {
            return try KeychainHelper.get(account: keychainAccount)
        } catch {
            Logger.shared.warn("[license] keychain read failed: \(error)")
            return nil
        }
    }

    private static func writeKeychain(_ token: String) {
        do {
            try KeychainHelper.set(token, account: keychainAccount)
        } catch {
            Logger.shared.warn("[license] keychain write failed: \(error)")
        }
    }

    private static func readFile() -> String? {
        let url = tokenJsonURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(TokenFile.self, from: data)
            return file.token
        } catch {
            Logger.shared.warn("[license] token.json read failed: \(error)")
            return nil
        }
    }

    private static func writeFile(_ token: String) {
        let dir = AppPaths.applicationSupportDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(TokenFile(token: token))
            try data.write(to: tokenJsonURL, options: [.atomic])
        } catch {
            Logger.shared.warn("[license] token.json write failed: \(error)")
        }
    }
}
