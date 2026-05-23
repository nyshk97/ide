import SwiftUI

/// アプリ全体で共有する toast/常駐エラーのチャネル。
///
/// **使い分けポリシー（要件 8.3）**:
/// - 単発で操作起因のエラー（書き込み失敗、bin が見つからない 等）→ `notify(_:)` で toast
/// - 継続的な状態異常（プロジェクト missing、watcher 停止、PTY 異常 等）→ それぞれの View 内で
///   常駐表示する（既存: missing project は LeftSidebarView の行内、PTY 異常は ExitedOverlayView）
///
/// このバスは「単発 toast」専用。詳細は ~/Library/Logs/ide/ にログとして残る。
@MainActor
final class ErrorBus: ObservableObject {
    static let shared = ErrorBus()

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let message: String
        let createdAt = Date.now
    }

    enum Kind {
        case error, warning, info
        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .info: return .blue
            }
        }
        var icon: String {
            switch self {
            case .error: return "xmark.octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    @Published var notices: [Notice] = []

    private init() {}

    /// toast を出して 4 秒後に自動で消す。
    func notify(_ message: String, kind: Kind = .error) {
        let notice = Notice(kind: kind, message: message)
        notices.append(notice)
        Logger.shared.write(kind == .error ? .error : (kind == .warning ? .warn : .info), message)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                self?.notices.removeAll { $0.id == notice.id }
            }
        }
    }

    func dismiss(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }
}

/// toast を画面右下に積む overlay。
struct ToastStackView: View {
    @ObservedObject var bus: ErrorBus = .shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(bus.notices) { notice in
                ToastRowView(notice: notice, onDismiss: { bus.dismiss(notice.id) })
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!bus.notices.isEmpty)
    }
}

private struct ToastRowView: View {
    let notice: ErrorBus.Notice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.kind.icon)
                .foregroundStyle(notice.kind.color)
            Text(notice.message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(3)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(notice.kind.color.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .frame(maxWidth: 360, alignment: .trailing)
    }
}
