import SwiftUI

/// `Cmd+D` で表示する diff オーバーレイ。
/// アクティブプロジェクト配下の Git repository diff を表示する。
/// `FullSearchView` と同じく `RootLayoutView` の `.overlay` に置く想定。
struct DiffOverlayView: View {
    @ObservedObject var viewModel: DiffViewModel
    let projectName: String
    let onClose: () -> Void

    @State private var selectedRepositoryID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .background(GitHubDark.border)
            if viewModel.repositories.count > 1 {
                repositoryTabs
                Divider()
                    .background(GitHubDark.border)
            }
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
        .onChange(of: repositoryIDs) { _, ids in
            guard let selectedRepositoryID, ids.contains(selectedRepositoryID) else {
                self.selectedRepositoryID = ids.first
                return
            }
        }
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
            if viewModel.totalFileCount > 0 {
                Text("\(viewModel.totalFileCount) files")
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

    private var repositoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.repositories) { repository in
                    repositoryTab(repository)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(GitHubDark.surfaceBackground)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.repositories.isEmpty {
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
        } else if viewModel.repositories.isEmpty {
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
            if let repository = selectedRepository {
                ScrollView {
                    if viewModel.repositories.count > 1 {
                        repositoryFiles(repository)
                            .padding(20)
                    } else {
                        repositorySection(repository)
                            .padding(20)
                    }
                }
            } else {
                Spacer()
            }
        }
    }

    private func repositoryTab(_ repository: RepositoryDiff) -> some View {
        let isSelected = repository.id == selectedRepository?.id
        let displayName = repositoryDisplayName(repository)
        return Button(action: { selectedRepositoryID = repository.id }) {
            HStack(spacing: 6) {
                Image("git-branch")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 12, height: 12)
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(repository.files.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(isSelected ? GitHubDark.background : GitHubDark.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected ? GitHubDark.text : GitHubDark.border)
                    )
            }
            .foregroundColor(isSelected ? GitHubDark.text : GitHubDark.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: 240)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? GitHubDark.background : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? GitHubDark.border : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("\(displayName) · \(repository.files.count) files")
    }

    private func repositorySection(_ repository: RepositoryDiff) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image("git-branch")
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 13, height: 13)
                    .foregroundColor(GitHubDark.textSecondary)
                Text(repositoryDisplayName(repository))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(GitHubDark.text)
                Text("\(repository.files.count) files")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(GitHubDark.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 2)

            repositoryFiles(repository)
        }
    }

    private func repositoryFiles(_ repository: RepositoryDiff) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(repository.files) { file in
                FileDiffCard(file: file, repoPath: repository.repoPath)
            }
        }
    }

    private var repositoryIDs: [String] {
        viewModel.repositories.map(\.id)
    }

    private var selectedRepository: RepositoryDiff? {
        if let selectedRepositoryID,
           let repository = viewModel.repositories.first(where: { $0.id == selectedRepositoryID }) {
            return repository
        }
        return viewModel.repositories.first
    }

    private func repositoryDisplayName(_ repository: RepositoryDiff) -> String {
        repository.displayPath == "." ? projectName : repository.displayPath
    }
}
