import AppKit
import SwiftUI

/// トライアル期限切れ or deactivated 状態のときに全 view を覆って表示する画面。
///
/// - 「14 日間のトライアルが終了しました」(or「ライセンスが無効化されました」) の見出し
/// - 価格 (¥11,800 / Lifetime License)
/// - 「購入する」ボタン (polepole.dev の購入ページへ)
/// - ライセンスキー入力フォーム
/// - お問い合わせフォーム (polepole.dev/contact) へのリンク
///
/// 要件 6 / 8.3 に従い、これが出ている間は背景の全機能 (メニュー操作も含む) を
/// 受け付けない。`ContentView` の ZStack overlay として最前面に重ねる。
struct PaywallView: View {
    @ObservedObject private var licenseStore = LicenseStore.shared

    @State private var key: String = ""
    @State private var email: String = ""
    @State private var swapDevices: [LicenseClient.ExistingDevice] = []
    @State private var showSwapSheet: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(headline)
                        .font(.title).bold()
                    Text(subhead)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Divider()

                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("¥11,800")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("Lifetime License")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("買い切り。すべての将来バージョンを無料アップデート。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: openPurchasePage) {
                        Text("購入する")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("ライセンスキーをお持ちの方")
                        .font(.headline)
                    TextField("メールアドレス", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    TextField("polepole-XXXX-XXXX-XXXX-XXXX", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    Button(action: activate) {
                        if licenseStore.activateInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("アクティベート")
                        }
                    }
                    .controlSize(.large)
                    .disabled(licenseStore.activateInProgress || !canActivate)

                    if let err = licenseStore.activateError, let msg = errorMessage(err) {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer().frame(height: 4)

                HStack(spacing: 16) {
                    Button("お問い合わせ") {
                        if let url = URL(string: "https://polepole.dev/contact") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    Button("ライセンスキーを再送") {
                        Task {
                            let trimmed = email.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                _ = await licenseStore.resendLicense(email: trimmed)
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .disabled(!email.contains("@"))
                }
                .font(.caption)
            }
            .padding(40)
            .frame(maxWidth: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 24)
        }
        .onChange(of: licenseStore.activateError) { _, err in
            if case .deviceLimit(let existing) = err {
                swapDevices = existing
                showSwapSheet = true
            }
        }
        .sheet(isPresented: $showSwapSheet) {
            DeviceSwapSheet(
                existingDevices: swapDevices,
                key: key.trimmingCharacters(in: .whitespaces),
                email: email.trimmingCharacters(in: .whitespaces)
            )
        }
    }

    // MARK: - Text

    private var headline: String {
        switch licenseStore.state {
        case .trialExpired: return "14 日間のトライアルが終了しました"
        case .deactivated: return "ライセンスが無効化されました"
        default: return ""
        }
    }

    private var subhead: String {
        switch licenseStore.state {
        case .trialExpired:
            return "PolePole を引き続きご利用いただくにはライセンスのご購入が必要です。"
        case .deactivated:
            return "30 日以上オンライン検証ができなかったため、ロックされました。\n再度アクティベートしてください。"
        default:
            return ""
        }
    }

    private var canActivate: Bool {
        !key.trimmingCharacters(in: .whitespaces).isEmpty &&
            email.contains("@")
    }

    private func openPurchasePage() {
        if let url = URL(string: "https://polepole.dev/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func activate() {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        Task {
            await licenseStore.activate(key: trimmedKey, email: trimmedEmail)
        }
    }

    private func errorMessage(_ err: LicenseClient.LicenseClientError) -> String? {
        switch err {
        case .invalidCredentials: return "メールアドレスまたはライセンスキーが正しくありません。"
        case .licenseRevoked: return "このライセンスは無効化されています。サポートにお問い合わせください。"
        case .licenseRefunded: return "このライセンスは返金処理されています。"
        case .rateLimited: return "リクエストが多すぎます。しばらく待ってから再試行してください。"
        case .deviceLimit: return nil  // sheet で扱う
        case .network(let msg): return "ネットワークエラー: \(msg)"
        case .server(let status, let msg): return "サーバエラー (\(status)): \(msg)"
        case .invalidBody: return "入力内容に問題があります。"
        case .unknownDevice, .deviceNotFound: return "デバイス情報が見つかりません。再度お試しください。"
        }
    }
}
