import SwiftUI
import AppKit

/// 画像ファイルの diff を変更前/変更後で並べる。DiffViewer の ImagePreviewView を移植。
/// 元実装との違い: `GitService` → `DiffService`、`repoPath: String` → `URL`、
/// 名前を `DiffImagePreviewView` に変更（IDE 内の他 ImagePreview と衝突回避）。
struct DiffImagePreviewView: View {
    let file: FileDiff
    let repoPath: URL

    var body: some View {
        HStack(spacing: 0) {
            if file.changeType == .deleted {
                imagePanel(title: "Deleted", image: oldImage, borderColor: GitHubDark.deletionBackground)
            } else if file.changeType == .new {
                imagePanel(title: "Added", image: newImage, borderColor: GitHubDark.additionBackground)
            } else {
                imagePanel(title: "Before", image: oldImage, borderColor: GitHubDark.deletionBackground)
                Rectangle()
                    .fill(GitHubDark.border)
                    .frame(width: 1)
                imagePanel(title: "After", image: newImage, borderColor: GitHubDark.additionBackground)
            }
        }
        .frame(minHeight: 100)
        .background(GitHubDark.background)
    }

    private func imagePanel(title: String, image: NSImage?, borderColor: Color) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(GitHubDark.textSecondary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400, maxHeight: 300)
                    .background(checkerboard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(borderColor, lineWidth: 2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                let size = image.size
                Text("\(Int(size.width))×\(Int(size.height))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(GitHubDark.textSecondary)
            } else {
                Text("(unavailable)")
                    .font(.system(size: 12))
                    .foregroundColor(GitHubDark.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var newImage: NSImage? {
        let path = repoPath.appendingPathComponent(file.fileName).path
        return NSImage(contentsOfFile: path)
    }

    private var oldImage: NSImage? {
        let data = DiffService.showFileData(fileName: file.fileName, repoPath: repoPath)
        guard let data, !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let squareSize: CGFloat = 8
            let cols = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    let isLight = (row + col) % 2 == 0
                    let rect = CGRect(x: CGFloat(col) * squareSize, y: CGFloat(row) * squareSize, width: squareSize, height: squareSize)
                    context.fill(Path(rect), with: .color(isLight ? Color(white: 0.2) : Color(white: 0.15)))
                }
            }
        }
    }
}
