import AppKit
import SwiftUI

/// Settings ウィンドウの「ライセンス」タブ。
///
/// - トライアル中: 残日数 + キー入力フォーム (Phase 6 で activate へ繋ぐ)
/// - アクティベート済み: メアド / ライセンスキー (マスク) / デバイス情報 + deactivate ボタン
/// - 期限切れ / deactivated: Paywall に誘導
///
/// Phase 5 ではトライアル状態の表示とキー入力欄を出すところまで。
/// activate ボタンは押せるが LicenseStore.activate が stub なので no-op。
struct LicenseSettingsView: View {
    @ObservedObject private var licenseStore = LicenseStore.shared

    @State private var key: String = ""
    @State private var email: String = ""
    @State private var isActivating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ライセンス")
                .font(.title2).bold()

            statusSection

            Divider()

            switch licenseStore.state {
            case .trial, .trialExpired, .deactivated:
                activationForm
            case .activated(let token):
                activatedSection(token: token)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        switch licenseStore.state {
        case .trial(let daysLeft):
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("トライアル中 (残り \(daysLeft) 日)")
                    .font(.headline)
            }
        case .activated:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("アクティベート済み")
                    .font(.headline)
            }
        case .trialExpired:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("トライアル期間が終了しています")
                    .font(.headline)
            }
        case .deactivated:
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.red)
                Text("無効化されています")
                    .font(.headline)
            }
        }
    }

    @ViewBuilder
    private var activationForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ライセンスキーを入力")
                .font(.headline)
            TextField("メールアドレス", text: $email)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
            TextField("polepole-XXXX-XXXX-XXXX-XXXX", text: $key)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
                .font(.system(.body, design: .monospaced))
            HStack {
                Button(action: activate) {
                    if isActivating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("アクティベート")
                    }
                }
                .disabled(isActivating || !canActivate)
                Button("購入ページを開く") {
                    if let url = URL(string: "https://polepole.dev/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func activatedSection(token: ActivationToken) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row("メール", value: token.payload.email)
            row("ライセンスキー", value: mask(token.payload.key))
            row("デバイス", value: token.payload.deviceHash.prefix(12) + "…")
            row("最終認証", value: issuedAtDisplay(token.payload.issuedAt))
            HStack {
                Button("このデバイスを deactivate") {
                    Task { await licenseStore.deactivate() }
                }
                .disabled(true)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: some StringProtocol) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 100, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
            Spacer()
        }
    }

    // MARK: - Helpers

    private var canActivate: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty &&
            email.contains("@")
    }

    private func activate() {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        isActivating = true
        Task {
            await licenseStore.activate(key: trimmedKey, email: trimmedEmail)
            isActivating = false
        }
    }

    private func mask(_ key: String) -> String {
        // polepole-XXXX-XXXX-XXXX-XXXX → polepole-XXXX-****-****-XXXX
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return String(key.prefix(8) + "…") }
        return [parts[0], parts[1], "****", "****", parts[4]].joined(separator: "-")
    }

    private func issuedAtDisplay(_ seconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }
}
