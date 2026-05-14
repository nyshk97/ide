import SwiftUI

/// `Cmd+D` で表示する diff オーバーレイ。
/// アクティブプロジェクトの `git diff` を集めて、`FileDiffCard` を縦に並べる。
/// `FullSearchView` と同じく `RootLayoutView` の `.overlay` に置く想定。
struct DiffOverlayView: View {
    @ObservedObject var viewModel: DiffViewModel
    let repoPath: URL
    let projectName: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(GitHubDark.border)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GitHubDark.background)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(GitHubDark.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("git-branch")
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundColor(GitHubDark.text)
            Text("Diff")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(GitHubDark.text)
            Text(projectName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(GitHubDark.textSecondary)
            if !viewModel.files.isEmpty {
                Text("\(viewModel.files.count) files")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(GitHubDark.textSecondary)
            }
            if viewModel.isLoading {
                ProgressView().scaleEffect(0.6).tint(GitHubDark.textSecondary)
            }
            Spacer()
            Button(action: { viewModel.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(GitHubDark.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
            .help("Reload (Cmd+R)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(GitHubDark.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Close (Esc / Cmd+D)")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(GitHubDark.surfaceBackground)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.files.isEmpty {
            VStack {
                Spacer()
                ProgressView().scaleEffect(1.2).tint(GitHubDark.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(GitHubDark.deletionText)
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundColor(GitHubDark.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.files.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundColor(GitHubDark.textSecondary)
                Text("No changes")
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(GitHubDark.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.files) { file in
                        FileDiffCard(file: file, repoPath: repoPath)
                    }
                }
                .padding(20)
            }
        }
    }
}
