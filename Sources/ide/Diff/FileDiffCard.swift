import SwiftUI

/// 1 ファイル分の diff カード。DiffViewer の `FileDiffView` を移植。
/// 元実装との違い:
/// - 名前: `FileDiffView` → `FileDiffCard`（IDE の `FilePreviewView` と紛らわしくないように）
/// - `repoPath: String` → `URL`
/// - `GitService` → `DiffService`
struct FileDiffCard: View {
    let file: FileDiff
    let repoPath: URL
    @State private var isExpanded = true
    @State private var showCopied = false
    @State private var showFullFile = false
    @State private var fullFileHunks: [DiffHunk]?
    @State private var isLoadingFullFile = false

    private var canShowFullFile: Bool {
        file.changeType != .new
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(GitHubDark.textSecondary)
                        .frame(width: 12)

                    Text(file.stage.rawValue)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(file.stage == .staged ? GitHubDark.stagedBadge : GitHubDark.unstagedBadge)
                        )

                    if case .renamed(let from) = file.changeType {
                        Text(from)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(GitHubDark.textSecondary)
                            .strikethrough(color: GitHubDark.textSecondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(GitHubDark.textSecondary)
                    }

                    Text(file.fileName)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(GitHubDark.text)

                    switch file.changeType {
                    case .new: fileBadge("NEW", color: GitHubDark.additionText)
                    case .deleted: fileBadge("DELETED", color: GitHubDark.deletionText)
                    case .renamed: fileBadge("RENAMED", color: GitHubDark.unstagedBadge)
                    case .modified: EmptyView()
                    }

                    Button(action: {
                        let pathToCopy = file.fileName
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pathToCopy, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            showCopied = false
                        }
                    }) {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(showCopied ? GitHubDark.additionText : GitHubDark.textSecondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }

                    if canShowFullFile {
                        Button(action: { toggleFullFile() }) {
                            Image(systemName: showFullFile ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11))
                                .foregroundColor(showFullFile ? GitHubDark.additionText : GitHubDark.textSecondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(showFullFile ? "差分のみ表示" : "ファイル全体を表示")
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(GitHubDark.fileHeader)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Rectangle()
                    .fill(GitHubDark.border)
                    .frame(height: 1)

                if file.isImageFile {
                    DiffImagePreviewView(file: file, repoPath: repoPath)
                } else if isLoadingFullFile {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(GitHubDark.background)
                } else {
                    let hunksToShow = showFullFile ? (fullFileHunks ?? file.hunks) : file.hunks
                    LazyVStack(spacing: 0) {
                        ForEach(hunksToShow) { hunk in
                            SideBySideDiffView(hunk: hunk, fileName: file.fileName)
                        }
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(GitHubDark.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func toggleFullFile() {
        showFullFile.toggle()
        if showFullFile && fullFileHunks == nil {
            isLoadingFullFile = true
            let fileName = file.fileName
            let stage = file.stage
            let changeType = file.changeType
            let path = repoPath
            Task.detached {
                let hunks = DiffService.fetchFullFileDiff(
                    fileName: fileName,
                    repoPath: path,
                    stage: stage,
                    changeType: changeType
                )
                await MainActor.run {
                    fullFileHunks = hunks
                    isLoadingFullFile = false
                }
            }
        }
    }

    private func fileBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
            )
    }
}
