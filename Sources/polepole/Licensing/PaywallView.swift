import AppKit
import SwiftUI

/// トライアル期限切れ or deactivated 状態のときに全 view を覆って表示する画面。
///
/// - 「14 日間のトライアルが終了しました」(or「ライセンスが無効化されました」) の見出し
/// - 価格 (¥11,800 / Lifetime License)
/// - 「購入する」ボタン (polepole.dev の購入ページへ)
/// - ライセンスキー入力フォーム (Phase 5 では disabled、Phase 6 で activate へ繋ぐ)
/// - サポートメール (support@polepole.dev)
///
/// 要件 6 / 8.3 に従い、これが出ている間は背景の全機能 (メニュー操作も含む) を
/// 受け付けない。`RootLayoutView` の overlay として ZStack で乗せる。
struct PaywallView: View {
    @ObservedObject private var licenseStore = LicenseStore.shared

    @State private var key: String = ""
    @State private var email: String = ""
    @State private var isActivating: Bool = false

    var body: some View {
        ZStack {
            // 背景を黒で覆って完全に遮断する
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                // 背景の hit-test を確実に吸う (overlay 下の view にイベントを通さない)
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
                    Text("既にライセンスをお持ちの方")
                        .font(.headline)
                    TextField("メールアドレス", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                    TextField("polepole-XXXX-XXXX-XXXX-XXXX", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                    Button(action: activate) {
                        if isActivating {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("アクティベート")
                        }
                    }
                    .controlSize(.large)
                    .disabled(isActivating || !canActivate)
                    // Phase 6 で実装するまでは押せても何も起きない (LicenseStore.activate は stub)
                }

                Spacer().frame(height: 4)

                HStack(spacing: 16) {
                    Button("お問い合わせ") {
                        if let url = URL(string: "mailto:support@polepole.dev") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    Button("ライセンスキーを再送") {
                        // TODO(Phase 6): LicenseClient.resend を呼ぶ
                    }
                    .buttonStyle(.link)
                    .disabled(true)
                }
                .font(.caption)
            }
            .padding(40)
            .frame(maxWidth: 520)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 24)
        }
    }

    private var headline: String {
        switch licenseStore.state {
        case .trialExpired: return "トライアル期間が終了しました"
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
        isActivating = true
        Task {
            await licenseStore.activate(key: trimmedKey, email: trimmedEmail)
            isActivating = false
        }
    }
}
