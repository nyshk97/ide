import SwiftUI
import AppKit
import PDFKit

/// 中央ペインのファイルプレビュー。閲覧専用、形式別に分岐表示。
struct FilePreviewView: View {
    @ObservedObject var preview: FilePreviewModel

    let url: URL
    /// プロジェクトルート。Markdown 内のローカルリンクをこの配下に制限する。
    let projectRoot: URL
    let onClose: () -> Void

    /// 5MB 超を「読み込む」ボタンで明示確認するための state。url が変わるたびリセット。
    @State private var forceLoadLarge = false

    /// 非同期で分類した結果。url 変更直後は nil で、その間は前の表示を維持して
    /// 「真っ白な瞬間」を作らない（小さいファイルなら 1〜2 frame で確定する）。
    @State private var kind: FilePreviewKind?
    @State private var loadedURL: URL?

    /// 自動リロードのたびにインクリメント。画像 / PDF は URL が同じだと
    /// `updateNSView` が再読込しないので、`.id()` に噛ませて作り直しを強制する。
    @State private var reloadGen = 0

    /// 「ツリー」パンくずリンクのホバー状態。clickable であることを示すため underline に使う。
    @State private var treeHovered = false
    /// ファイル名パンくずのホバー状態。クリックで相対パスをコピーできることを示す。
    @State private var nameHovered = false

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
            // 同じ url が連続で渡る（履歴で同ファイルに戻る等）は初回ロードをスキップ
            if !(loadedURL == url && kind != nil) {
                await classifyAndApply()
            }
            // 表示中ファイルがディスク上で更新されたら自動でリロード。
            // url が変わる / ツリーに戻ると .task が cancel され、watcher も止まる。
            for await _ in FileChangeWatcher.events(for: url) {
                if Task.isCancelled { break }
                await classifyAndApply(isReload: true)
            }
        }
        // 「読み込む」確認を経たら、サイズしきい値を無視して再分類する。
        // 巨大ファイルの読み込みも View body ではなく classify の Task 経路で行う。
        .onChange(of: forceLoadLarge) { _, allow in
            if allow {
                Task { await classifyAndApply() }
            }
        }
    }

    /// ファイルを分類し直して表示状態に反映する。`.task` 初回と自動リロードの両方が呼ぶ。
    private func classifyAndApply(isReload: Bool = false) async {
        let target = url
        let allowLarge = forceLoadLarge
        let result = await Task.detached(priority: .userInitiated) {
            FilePreviewClassifier.classify(target, allowLarge: allowLarge)
        }.value
        if Task.isCancelled { return }
        self.kind = result
        self.loadedURL = target
        if isReload {
            self.reloadGen &+= 1
            Logger.shared.debug("[preview] auto-reloaded \(target.lastPathComponent)")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            // パンくず: 📁 / filename
            HStack(spacing: 4) {
                Button(action: onClose) {
                    Image(systemName: "folder")
                        .foregroundStyle(treeHovered ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Esc でツリーに戻る")
                .onHover { treeHovered = $0 }

                Text("/")
                    .foregroundStyle(.tertiary)

                Button(action: copyRelativePath) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .underline(nameHovered)
                }
                .buttonStyle(.plain)
                .help("クリックで相対パスをコピー")
                .onHover { nameHovered = $0 }
            }

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

            Button {
                openInCursor(url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                Text("Cursor で開く")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: [.command, .option])
            .help("Cmd+Option+O で Cursor を起動")
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
                webPreview(payload: PreviewPayload(
                    kind: .markdown,
                    text: text,
                    lang: "",
                    baseURL: url.deletingLastPathComponent(),
                    allowedRoot: projectRoot
                ))
            case .image:
                ImagePreview(url: url)
                    .id(reloadGen)
            case .pdf:
                PDFPreview(url: url)
                    .id(reloadGen)
            case .binary:
                externalPrompt(message: "バイナリファイルです（プレビュー非対応）")
            case .tooLarge(let bytes):
                // 「読み込む」を押すと forceLoadLarge=true → 再分類で実際の種別に変わるので、
                // ここに来ている時点では常に確認 UI を出す。
                largeFilePrompt(bytes: bytes)
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
        // マークダウン内のローカルリンクは preview のスタックに乗せて開く。
        // コードプレビューでも害はないので一律で配線しておく。
        PreviewWebView(payload: payload, onLinkToFile: { linked in
            preview.open(linked.standardizedFileURL)
        })
    }

    private func codePayload(data: Data) -> PreviewPayload {
        let text = String(data: data, encoding: .utf8) ?? "(decode failed)"
        return PreviewPayload(kind: .code, text: text, lang: PreviewLanguage.guess(from: url), allowedRoot: projectRoot)
    }

    private func externalPrompt(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(message).foregroundStyle(.secondary)
            Button("Cursor で開く") { openInCursor(url) }
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
                Button("Cursor で開く") { openInCursor(url) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// プロジェクトルートからの相対パスをクリップボードへコピーする。
    /// ルート配下でなければ絶対パスにフォールバックする（PreviewWebView の挙動に合わせる）。
    private func copyRelativePath() {
        let rootPath = projectRoot.standardizedFileURL.path
        let abs = url.standardizedFileURL.path
        let rel: String
        if abs.hasPrefix(rootPath + "/") {
            rel = String(abs.dropFirst(rootPath.count + 1))
        } else {
            rel = abs
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rel, forType: .string)
        ErrorBus.shared.notify("相対パスをコピーしました: \(rel)", kind: .info)
    }

    private func openInCursor(_ url: URL) {
        // `cursor` コマンドが PATH 配下にある想定。argv 配列で起動（要件 8.1）。
        guard let cursorPath = BinaryLocator.cursor else {
            // フォールバック: NSWorkspace で開く
            NSWorkspace.shared.open(url)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cursorPath)
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
