import SwiftUI

/// DiffViewer から移植した 1 hunk のサイドバイサイド表示。
/// 元実装との違い: `SyntaxHighlighter` → `DiffSyntaxHighlighter` への参照置き換え。
struct SideBySideDiffView: View {
    let hunk: DiffHunk
    let fileName: String

    var body: some View {
        let pairs = buildSideBySidePairs(hunk.lines)

        LazyVStack(spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 0) {
                    lineNumberColumn(pair.left?.oldLineNumber ?? pair.left?.newLineNumber)
                    lineContent(pair.left)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle()
                        .fill(GitHubDark.border)
                        .frame(width: 1)

                    lineNumberColumn(pair.right?.newLineNumber ?? pair.right?.oldLineNumber)
                    lineContent(pair.right)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 20)
            }
        }
    }

    private func lineNumberColumn(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(GitHubDark.lineNumberText)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 8)
    }

    private func lineContent(_ line: DiffLine?) -> some View {
        let bg: Color
        let highlighted: AttributedString

        if let line {
            switch line.type {
            case .addition: bg = GitHubDark.additionBackground
            case .deletion: bg = GitHubDark.deletionBackground
            case .context: bg = .clear
            }
            highlighted = DiffSyntaxHighlighter.highlight(line.content, fileName: fileName)
        } else {
            bg = GitHubDark.surfaceBackground
            highlighted = AttributedString("")
        }

        return Text(highlighted)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(bg)
    }

    private func buildSideBySidePairs(_ lines: [DiffLine]) -> [(left: DiffLine?, right: DiffLine?)] {
        var pairs: [(left: DiffLine?, right: DiffLine?)] = []
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []

        func flushPending() {
            let count = max(deletions.count, additions.count)
            for i in 0..<count {
                let left = i < deletions.count ? deletions[i] : nil
                let right = i < additions.count ? additions[i] : nil
                pairs.append((left: left, right: right))
            }
            deletions = []
            additions = []
        }

        for line in lines {
            switch line.type {
            case .context:
                flushPending()
                pairs.append((left: line, right: line))
            case .deletion:
                deletions.append(line)
            case .addition:
                additions.append(line)
            }
        }
        flushPending()

        return pairs
    }
}
