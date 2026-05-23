import Foundation

/// 14 日トライアル期間の管理。
///
/// install date を **Keychain と Application Support の trial.json の両方に書き、起動時には
/// 両方を読んで min を採用** する。片方しか無いときはもう片方を補完書きする。これにより:
/// - Keychain だけ消した: trial.json から復元 (= Keychain に再書き)
/// - trial.json だけ消した: Keychain から復元 (= trial.json に再書き)
/// - 両方消した: 新規 install 扱いで now() を書く (= リセットになる)
///
/// サーバには一切通知せず anonymous。
///
/// テストフック: 環境変数 `POLEPOLE_TEST_LICENSE_FAKE_NOW` (Unix 秒) で now() を上書きできる。
/// 14 日後の screenshot 取得などで使う。
final class TrialManager: @unchecked Sendable {
    static let shared = TrialManager()

    static let trialDurationDays: Int = 14

    private let fileManager = FileManager.default
    private let isoFormatter: ISO8601DateFormatter
    private let keychainAccount = "trial-install-date"

    private init() {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        self.isoFormatter = fmt
    }

    private var trialJsonURL: URL {
        AppPaths.applicationSupportDirectory.appendingPathComponent("trial.json")
    }

    /// 「現在時刻」。テストフックがあれば優先する。
    static var now: Date {
        if let raw = ProcessInfo.processInfo.environment["POLEPOLE_TEST_LICENSE_FAKE_NOW"],
           let secs = TimeInterval(raw)
        {
            return Date(timeIntervalSince1970: secs)
        }
        return .now
    }

    /// install date を確定して返す。
    ///
    /// 1. Keychain と trial.json の両方を読む
    /// 2. 両方に値があれば min を採用、片方しか無ければそれを採用、両方無ければ now() を採用
    /// 3. 採用した値を「持っていない方」に補完書きする (両方に同じ値が揃うようにする)
    func installDate() -> Date {
        let fromKeychain = readKeychain()
        let fromFile = readTrialJson()

        let resolved: Date
        switch (fromKeychain, fromFile) {
        case let (k?, f?):
            resolved = min(k, f)
        case (let k?, nil):
            resolved = k
        case (nil, let f?):
            resolved = f
        case (nil, nil):
            resolved = Self.now
        }

        if fromKeychain != resolved { writeKeychain(resolved) }
        if fromFile != resolved { writeTrialJson(resolved) }

        return resolved
    }

    /// 残り日数 (0 未満は 0 にクランプ)。
    /// `daysRemaining() == 0` のとき `LicenseStore` は `.trialExpired` に遷移する。
    func daysRemaining() -> Int {
        let install = installDate()
        let elapsedSeconds = Self.now.timeIntervalSince(install)
        let elapsedDays = Int(floor(elapsedSeconds / 86400))
        let remaining = Self.trialDurationDays - elapsedDays
        return max(0, remaining)
    }

    // MARK: - Keychain

    private func readKeychain() -> Date? {
        do {
            guard let str = try KeychainHelper.get(account: keychainAccount) else { return nil }
            return isoFormatter.date(from: str)
        } catch {
            Logger.shared.warn("[trial] keychain read failed: \(error)")
            return nil
        }
    }

    private func writeKeychain(_ date: Date) {
        do {
            try KeychainHelper.set(isoFormatter.string(from: date), account: keychainAccount)
        } catch {
            Logger.shared.warn("[trial] keychain write failed: \(error)")
        }
    }

    // MARK: - Application Support (trial.json)

    private struct TrialFile: Codable {
        let installDate: Date
    }

    private func readTrialJson() -> Date? {
        let url = trialJsonURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(TrialFile.self, from: data)
            return file.installDate
        } catch {
            Logger.shared.warn("[trial] trial.json read failed: \(error)")
            return nil
        }
    }

    private func writeTrialJson(_ date: Date) {
        let dir = AppPaths.applicationSupportDirectory
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(TrialFile(installDate: date))
            try data.write(to: trialJsonURL, options: [.atomic])
        } catch {
            Logger.shared.warn("[trial] trial.json write failed: \(error)")
        }
    }
}
