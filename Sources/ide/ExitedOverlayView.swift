import SwiftUI

/// シェル/コマンドが終了したタブ上に重ねる通知 overlay。
/// 自動でタブを閉じず、ユーザーが exit code を見たうえで再起動できるようにする。
struct ExitedOverlayView: View {
    let exitCode: UInt32
    let onRestart: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 28))
                .foregroundStyle(.red.opacity(0.85))
            Text("Shell exited")
                .font(.system(size: 14, weight: .semibold))
            Text("exit code: \(exitCode)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(action: onRestart) {
                Label("Restart", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 8)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
    }
}
