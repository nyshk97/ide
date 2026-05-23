import SwiftUI

/// Ctrl+M で表示する MRU プロジェクト切替オーバーレイ。
///
/// ウィンドウ中央に小さなパネルとして被さる。Ctrl 押しっぱなしのまま M 連打で
/// サイクル、Ctrl 離して確定、Esc キャンセルは `MRUKeyMonitor` が捕捉する。
struct MRUOverlayView: View {
    let state: MRUOverlayState

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.candidates.enumerated()), id: \.element.id) { index, project in
                row(project: project, isSelected: index == state.selection)
            }
        }
        .padding(8)
        .frame(width: 360)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
    }

    private func row(project: Project, isSelected: Bool) -> some View {
        let missing = project.isMissing
        return HStack(spacing: 8) {
            ProjectAvatarView(
                name: project.displayName,
                colorKey: project.colorKey,
                isMissing: missing,
                size: 22
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.system(size: 13, weight: project.isPinned ? .semibold : .regular))
                    .lineLimit(1)
                Text(project.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(missing ? 0.55 : 1.0)
    }
}
