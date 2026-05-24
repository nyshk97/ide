import Foundation
import SwiftUI

/// アプリ全体のライセンス状態 (singleton)。
///
/// 起動時に `ActivationTokenStore` → `TokenVerifier` → 有効な token があれば `.activated`、
/// 無ければ `TrialManager` の install date から残日数を計算してトライアル経路に乗せる。
///
/// `state.isLocked == true` のときに `PaywallView` が overlay として全 view を覆い、
/// 機能を停止する (要件 6 / 8.3)。
@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    @Published private(set) var state: LicenseState

    /// activate のエラー (.deviceLimit 時は既存デバイス一覧を保持)。
    /// PaywallView / LicenseSettingsView が読んでスワップダイアログを出す。
    @Published var activateError: LicenseClient.LicenseClientError?
    @Published var activateInProgress: Bool = false

    /// 直近の verify 試行時刻 (起動時に複数回 verify が走らないように)。
    private var lastVerifyAttempt: Date?

    /// 起動時リマインド (残 3 日以下) を 1 セッションで何度も出さないためのフラグ。
    /// プロセス再起動でリセットされて構わない (= 起動ごとに 1 回出すのが目的)。
    private var didEmitStartupTrialReminder: Bool = false

    /// 時計巻き戻し対策: これまでに観測した最大の now を Keychain に保存する。
    /// 判定時は `max(actualNow, lastObservedNow)` を使う。
    private let lastObservedNowAccount = "last-observed-now"

    private let client: LicenseClient

    init() {
        self.client = LicenseClient()
        self.state = .trial(daysLeft: TrialManager.trialDurationDays)
        refreshFromDisk()
    }

    /// 起動時 / アプリ復帰時 / activate/deactivate 後に状態を再計算する。
    func refreshFromDisk() {
        if let raw = ActivationTokenStore.load() {
            do {
                let token = try TokenVerifier.verify(raw)
                let now = monotonicNow()
                let expiresAt = token.payload.issuedAt + Int64(token.payload.maxOfflineDays) * 86400
                if Int64(now.timeIntervalSince1970) <= expiresAt {
                    state = .activated(token: token)
                    Logger.shared.info(
                        "[license] state = activated (expires in \(secondsToDays(expiresAt - Int64(now.timeIntervalSince1970))) days)"
                    )
                    return
                } else {
                    Logger.shared.info("[license] token expired (issued_at + 30d < now), -> deactivated")
                    state = .deactivated
                    return
                }
            } catch {
                Logger.shared.warn("[license] token verify failed: \(error). falling back to trial path")
                // 検証に失敗したトークンは消す (改竄 or 鍵不一致 or 破損)
                ActivationTokenStore.clear()
            }
        }
        // Token が無い or 検証失敗 → トライアル経路
        let daysLeft = TrialManager.shared.daysRemaining()
        if daysLeft <= 0 {
            state = .trialExpired
        } else {
            state = .trial(daysLeft: daysLeft)
        }
        Logger.shared.info("[license] state = \(stateLabel(state))")
    }

    // MARK: - Activation

    /// ユーザーが入力したキーとメアドでアクティベーションを試みる。
    func activate(key: String, email: String) async {
        activateInProgress = true
        activateError = nil
        defer { activateInProgress = false }

        let deviceHash = DeviceIdentifier.deviceHash()
        let deviceName = DeviceIdentifier.deviceName()
        let osVersion = DeviceIdentifier.osVersion()
        let appVersion = DeviceIdentifier.appVersion()

        do {
            let response = try await client.activate(
                key: key,
                email: email,
                deviceHash: deviceHash,
                deviceName: deviceName,
                osVersion: osVersion,
                appVersion: appVersion
            )
            ActivationTokenStore.save(response.token)
            Logger.shared.info("[license] activate ok: device_id=\(response.device.id)")
            refreshFromDisk()
        } catch let err as LicenseClient.LicenseClientError {
            activateError = err
            Logger.shared.warn("[license] activate failed: \(err)")
        } catch {
            activateError = .network(message: error.localizedDescription)
            Logger.shared.warn("[license] activate failed: \(error)")
        }
    }

    /// device_limit のときに「old device を消して再 activate」を 1 アクションで行う。
    func swapAndActivate(removing existingDeviceId: String, key: String, email: String) async {
        activateInProgress = true
        defer { activateInProgress = false }
        do {
            _ = try await client.deactivate(key: key, email: email, deviceId: existingDeviceId)
        } catch {
            activateError = .network(message: "swap deactivate failed: \(error)")
            return
        }
        await activate(key: key, email: email)
    }

    /// このデバイスを deactivate する。サーバが消した上で、ローカルの token を消去。
    func deactivate() async {
        guard case .activated(let token) = state else { return }
        // device_id を持っていないが、サーバは device_hash 一致で消せない (deactivate は id 必須)。
        // 起動時に device_id を取得する経路が無いので Phase 6 では「ローカル token を捨てるだけ」
        // でひとまず扱う。サーバ側のデバイス枠を空けたい場合は別の管理 UI が必要。
        // TODO: Phase 7 で「全デバイス一覧 + 個別 deactivate」を Settings に追加する
        _ = token
        ActivationTokenStore.clear()
        Logger.shared.info("[license] local deactivate (token cleared)")
        refreshFromDisk()
    }

    /// 紛失ライセンスの再送。
    func resendLicense(email: String) async -> Bool {
        do {
            _ = try await client.resend(email: email)
            return true
        } catch {
            Logger.shared.warn("[license] resend failed: \(error)")
            return false
        }
    }

    // MARK: - Startup reminders

    /// 起動直後 (ContentView.onAppear) に呼ぶ。
    /// トライアル残り 3 日以下のとき、1 セッション 1 回だけ toast を出す。
    func emitStartupTrialReminderIfNeeded() {
        guard !didEmitStartupTrialReminder else { return }
        guard case .trial(let daysLeft) = state, daysLeft <= 3 else { return }
        didEmitStartupTrialReminder = true
        let msg: String
        if daysLeft <= 0 {
            // ここに来るのは PaywallView 表示と入れ替わる境界条件のみだが念のため。
            msg = "PolePole のトライアルが本日終了します。"
        } else if daysLeft == 1 {
            msg = "PolePole のトライアルは残り 1 日です。"
        } else {
            msg = "PolePole のトライアルは残り \(daysLeft) 日です。"
        }
        ErrorBus.shared.notify(msg, kind: .warning)
    }

    // MARK: - Verify (週1)

    /// 必要なら verify を 1 回走らせる。
    /// - 起動時に呼ばれる。`lastVerifyAttempt` 内に 7 日経っていれば実行。
    /// - 失敗してもトークンは温存し、`issued_at + 30 日` でローカル grace が切れる。
    /// - 成功時は新しいトークンを保存して issued_at を更新 (= grace が連続的に延長)。
    func verifyIfNeeded() async {
        guard case .activated(let token) = state else { return }
        let now = monotonicNow()
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(token.payload.issuedAt))
        let daysSinceIssued = now.timeIntervalSince(issuedAt) / 86400
        if daysSinceIssued < 7 {
            return
        }
        if let last = lastVerifyAttempt, now.timeIntervalSince(last) < 86400 {
            return
        }
        lastVerifyAttempt = now

        do {
            let response = try await client.verify(
                key: token.payload.key,
                email: token.payload.email,
                deviceHash: token.payload.deviceHash,
                osVersion: DeviceIdentifier.osVersion(),
                appVersion: DeviceIdentifier.appVersion()
            )
            ActivationTokenStore.save(response.token)
            Logger.shared.info("[license] verify ok: token refreshed")
            refreshFromDisk()
        } catch LicenseClient.LicenseClientError.licenseRevoked,
                LicenseClient.LicenseClientError.licenseRefunded,
                LicenseClient.LicenseClientError.unknownDevice,
                LicenseClient.LicenseClientError.invalidCredentials {
            // 明示的に server が「無効」と返したケース: ローカル token を捨てる
            Logger.shared.warn("[license] verify rejected, clearing token")
            ActivationTokenStore.clear()
            refreshFromDisk()
        } catch {
            // ネットワーク or rate limit 等の一時的失敗: token は温存し grace を待つ
            Logger.shared.warn("[license] verify temp failed: \(error)")
            emitGraceRemainingToast(token: token)
        }
    }

    /// verify 失敗時 (一時的なネットワーク異常) に「再検証失敗、grace 残り N 日」を toast 表示する。
    /// grace 残りが 14 日を切ったら警告色 (warning)、4 日以下に切ったらエラー色 (error) で出す。
    /// それより余裕があるときは info で静かめに通知。
    private func emitGraceRemainingToast(token: ActivationToken) {
        let nowSecs = Int64(monotonicNow().timeIntervalSince1970)
        let expiresAt = token.payload.issuedAt + Int64(token.payload.maxOfflineDays) * 86400
        let remaining = max(0, Int((expiresAt - nowSecs) / 86400))
        let kind: ErrorBus.Kind
        if remaining <= 4 {
            kind = .error
        } else if remaining <= 14 {
            kind = .warning
        } else {
            kind = .info
        }
        let msg = "ライセンスの再検証に失敗しました。あと \(remaining) 日でロックされます (ネットワーク要確認)"
        ErrorBus.shared.notify(msg, kind: kind)
    }

    // MARK: - Helpers

    /// 「現在時刻」(時計巻き戻し対策込み)。Keychain の last-observed-now と max を取り、
    /// 観測値を更新する。POLEPOLE_TEST_LICENSE_FAKE_NOW にも追随する。
    private func monotonicNow() -> Date {
        let actual = TrialManager.now
        let last = readLastObservedNow() ?? Date(timeIntervalSince1970: 0)
        let resolved = max(actual, last)
        if actual > last {
            writeLastObservedNow(actual)
        }
        return resolved
    }

    private func readLastObservedNow() -> Date? {
        do {
            guard let raw = try KeychainHelper.get(account: lastObservedNowAccount),
                  let secs = TimeInterval(raw)
            else { return nil }
            return Date(timeIntervalSince1970: secs)
        } catch {
            return nil
        }
    }

    private func writeLastObservedNow(_ date: Date) {
        try? KeychainHelper.set(
            String(Int64(date.timeIntervalSince1970)),
            account: lastObservedNowAccount
        )
    }

    private func secondsToDays(_ secs: Int64) -> Int { Int(secs / 86400) }

    private func stateLabel(_ s: LicenseState) -> String {
        switch s {
        case .trial(let d): return "trial(\(d) days left)"
        case .activated: return "activated"
        case .trialExpired: return "trialExpired"
        case .deactivated: return "deactivated"
        }
    }
}
