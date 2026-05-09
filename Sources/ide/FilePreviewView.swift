import SwiftUI
import AppKit
import PDFKit

/// 中央ペインのファイルプレビュー。閲覧専用、形式別に分岐表示。
struct FilePreviewView: View {
    let url: URL
    let onClose: () -> Void

    /// 5MB 超を「読み込む」ボタンで明示確認するための state。
    @State private var forceLoadLarge = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                Text("ツリーに戻る")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                openInVSCode(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                Text("VSCode で開く")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: [.command, .option])
            .help("Cmd+Option+O で VSCode を起動")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        let kind = FilePreviewClassifier.classify(url)
        switch kind {
        case .code(let data, _):
            CodePreview(data: data)
        case .markdown(let text):
            MarkdownPreview(text: text)
        case .image:
            ImagePreview(url: url)
        case .pdf:
            PDFPreview(url: url)
        case .binary:
            externalPrompt(message: "バイナリファイルです（プレビュー非対応）")
        case .tooLarge(let bytes):
            if forceLoadLarge {
                CodePreview(data: (try? Data(contentsOf: url)) ?? Data())
            } else {
                largeFilePrompt(bytes: bytes)
            }
        case .external:
            externalPrompt(message: "ファイルサイズが大きいか UTF-8 でないため外部で開いてください")
        case .error(let msg):
            VStack {
                Spacer()
                Text(msg).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func externalPrompt(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(message).foregroundStyle(.secondary)
            Button("VSCode で開く") { openInVSCode(url) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func largeFilePrompt(bytes: Int64) -> some View {
        let mb = Double(bytes) / 1024.0 / 1024.0
        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(String(format: "%.1f MB のファイルです。読み込みますか？", mb))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("読み込む") { forceLoadLarge = true }
                Button("VSCode で開く") { openInVSCode(url) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openInVSCode(_ url: URL) {
        let process = Process()
        // `code` コマンドが PATH 配下にある想定。argv 配列で起動（要件 8.1）。
        let candidates = ["/usr/local/bin/code", "/opt/homebrew/bin/code"]
        guard let codePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            // フォールバック: NSWorkspace で開く
            NSWorkspace.shared.open(url)
            return
        }
        process.executableURL = URL(fileURLWithPath: codePath)
        process.arguments = [url.path]
        try? process.run()
    }
}

// MARK: - 種別ごとのレンダリング

private struct CodePreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let text = String(data: data, encoding: .utf8) ?? "(decode failed)"
        textView.string = text
    }
}

private struct MarkdownPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            // AttributedString.init(markdown:) は inline のみだが MVP として十分。
            // ブロック（見出し、リスト等）は素朴にプレーン表示でいく。
            if let attributed = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }
}

private struct ImagePreview: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            }
        } else {
            Text("画像を読み込めませんでした").foregroundStyle(.secondary)
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
