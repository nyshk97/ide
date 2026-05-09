import SwiftUI
import AppKit
import PDFKit

/// 中央ペインのファイルプレビュー。閲覧専用、形式別に分岐表示。
struct FilePreviewView: View {
    @ObservedObject var preview: FilePreviewModel

    let url: URL
    let onClose: () -> Void

    /// 5MB 超を「読み込む」ボタンで明示確認するための state。url が変わるたびリセット。
    @State private var forceLoadLarge = false

    /// 非同期で分類した結果。url 変更直後は nil で、その間は前の表示を維持して
    /// 「真っ白な瞬間」を作らない（小さいファイルなら 1〜2 frame で確定する）。
    @State private var kind: FilePreviewKind?
    @State private var loadedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: url) {
            forceLoadLarge = false
            // 同じ url が連続で渡る（履歴で同ファイルに戻る等）はスキップ
            if loadedURL == url, kind != nil { return }
            let target = url
            let result = await Task.detached(priority: .userInitiated) {
                FilePreviewClassifier.classify(target)
            }.value
            if Task.isCancelled { return }
            self.kind = result
            self.loadedURL = target
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

            // 履歴ナビ
            Button { preview.goBack() } label: {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(.plain)
            .disabled(!preview.canGoBack)
            .help("前のファイル")

            Button { preview.goForward() } label: {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.plain)
            .disabled(!preview.canGoForward)
            .help("次のファイル")

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
        // 分類待ちの一瞬は前回の WebView 表示をそのまま見せたいので、
        // 何も描画しない（透明）。SwiftUI が前 frame を保持する。
        if let kind = (loadedURL == url) ? kind : nil {
            switch kind {
            case .code(let data, _):
                webPreview(payload: codePayload(data: data))
            case .markdown(let text):
                webPreview(payload: PreviewPayload(kind: .markdown, text: text, lang: ""))
            case .image:
                ImagePreview(url: url)
            case .pdf:
                PDFPreview(url: url)
            case .binary:
                externalPrompt(message: "バイナリファイルです（プレビュー非対応）")
            case .tooLarge(let bytes):
                if forceLoadLarge {
                    webPreview(payload: codePayload(data: (try? Data(contentsOf: url)) ?? Data()))
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
        } else {
            Color.clear
        }
    }

    private func webPreview(payload: PreviewPayload) -> some View {
        PreviewWebView(payload: payload)
    }

    private func codePayload(data: Data) -> PreviewPayload {
        let text = String(data: data, encoding: .utf8) ?? "(decode failed)"
        return PreviewPayload(kind: .code, text: text, lang: PreviewLanguage.guess(from: url))
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

// MARK: - 拡張子から highlight.js 用の言語名を推定

enum PreviewLanguage {
    static func guess(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let v = byExt[ext] { return v }
        // 拡張子のない有名ファイル
        switch url.lastPathComponent {
        case "Dockerfile": return "dockerfile"
        case "Makefile": return "makefile"
        case "Brewfile", "Gemfile", "Rakefile", "Podfile": return "ruby"
        default: return ""
        }
    }

    private static let byExt: [String: String] = [
        "swift": "swift",
        "py": "python",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "go": "go",
        "rs": "rust",
        "rb": "ruby",
        "yml": "yaml", "yaml": "yaml",
        "json": "json", "json5": "json",
        "toml": "toml",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "html": "xml", "htm": "xml",
        "xml": "xml", "plist": "xml", "svg": "xml",
        "css": "css",
        "scss": "scss", "sass": "scss", "less": "less",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "m": "objectivec", "mm": "objectivec",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "php": "php",
        "sql": "sql",
        "lua": "lua",
        "pl": "perl",
        "dart": "dart",
        "zig": "zig",
        "ini": "ini", "conf": "ini",
        "diff": "diff", "patch": "diff",
        "dockerfile": "dockerfile",
        "graphql": "graphql", "gql": "graphql",
        "tf": "hcl", "hcl": "hcl",
    ]
}

// MARK: - 種別ごとのレンダリング

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
