import SwiftUI

/// activate のレスポンスが `device_limit` のとき、既存 3 デバイスのうち 1 つを選んで
/// 入れ替える sheet。
///
/// 親 View (PaywallView / LicenseSettingsView) は `LicenseStore.activateError` が
/// `.deviceLimit(existing:)` のときに `.sheet(isPresented:)` でこの view を出す。
struct DeviceSwapSheet: View {
    let existingDevices: [LicenseClient.ExistingDevice]
    let key: String
    let email: String

    @ObservedObject private var licenseStore = LicenseStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDeviceId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("デバイス上限に達しました")
                .font(.title2).bold()
            Text("このライセンスは既に 3 台で使われています。新しいデバイス (このマシン) で使うには、既存のどれかを入れ替えてください。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 8) {
                ForEach(existingDevices) { device in
                    deviceRow(device)
                }
            }

            Spacer()

            HStack {
                Button("キャンセル") { dismiss() }
                Spacer()
                Button(action: swap) {
                    if licenseStore.activateInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("選択したデバイスを外して、このマシンを追加")
                    }
                }
                .disabled(selectedDeviceId == nil || licenseStore.activateInProgress)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }

    @ViewBuilder
    private func deviceRow(_ device: LicenseClient.ExistingDevice) -> some View {
        Button {
            selectedDeviceId = device.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedDeviceId == device.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedDeviceId == device.id ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.device_name ?? "(name unknown)")
                        .font(.headline)
                    HStack(spacing: 8) {
                        if let os = device.os_version {
                            Text(os).font(.caption).foregroundStyle(.secondary)
                        }
                        if let app = device.app_version {
                            Text("PolePole \(app)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("最終利用: \(relativeDate(device.last_seen_at))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selectedDeviceId == device.id ? Color.accentColor : Color.secondary.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
    }

    private func swap() {
        guard let id = selectedDeviceId else { return }
        Task {
            await licenseStore.swapAndActivate(removing: id, key: key, email: email)
            if licenseStore.activateError == nil {
                dismiss()
            }
        }
    }

    private func relativeDate(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: TrialManager.now)
    }
}
