import AppKit
import SwiftUI

/// 4 カラムレイアウトの 3 列目「プレビュー専用ペイン」。
/// `RootLayoutView` から SplitViewItem として常時マウントされ、
/// `ProjectsModel.activePreviewVisible == false` のときは `isCollapsed` で物理的に隠される。
///
/// 中身は **active project の `FilePreviewView` を 1 つだけ** if-let で描画する。
/// `PreviewWebController.shared.webView` が singleton な WKWebView を返すため
/// （`PreviewWebView.swift:311-319`）、複数プロジェクトの `FilePreviewView` を
/// 同時にマウントすると同じ WebView が複数箇所に乗ってクラッシュする。
struct FilePreviewPaneView: View {
    @ObservedObject var projects: ProjectsModel = .shared

    var body: some View {
        Group {
            if let active = projects.activeProject {
                ActivePreview(
                    preview: projects.preview(for: active),
                    projectRoot: active.path
                )
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// active project の preview を 1 つだけ描画。currentURL が nil のとき（プレビュー閉）
/// は何も出さない（このとき親の SplitViewItem は isCollapsed なので不可視のはず）。
private struct ActivePreview: View {
    @ObservedObject var preview: FilePreviewModel
    let projectRoot: URL

    var body: some View {
        if let url = preview.currentURL {
            PreviewFocusHost(preview: preview, url: url, projectRoot: projectRoot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// `FilePreviewView` を `PreviewFocusHostingView` で包み、Esc / Cmd+W を
/// 「プレビュー配下にフォーカスがあるとき限定」で捕捉する。
///
/// グローバル捕捉 (MRUKeyMonitor) では Ghostty 側の Cmd+W (terminal tab close) を壊すため
/// 採用しない。
private struct PreviewFocusHost: NSViewRepresentable {
    @ObservedObject var preview: FilePreviewModel
    let url: URL
    let projectRoot: URL

    func makeNSView(context: Context) -> PreviewFocusHostingView<FilePreviewView> {
        let view = FilePreviewView(
            preview: preview,
            url: url,
            projectRoot: projectRoot
        )
        let host = PreviewFocusHostingView(rootView: view)
        host.onClose = { [weak preview] in preview?.close() }
        return host
    }

    func updateNSView(_ nsView: PreviewFocusHostingView<FilePreviewView>, context: Context) {
        nsView.rootView = FilePreviewView(
            preview: preview,
            url: url,
            projectRoot: projectRoot
        )
        nsView.onClose = { [weak preview] in preview?.close() }
    }
}

/// `PreviewFocusHostingView` の非ジェネリックなマーカー。
/// `MRUKeyMonitor` が「first responder がプレビュー配下か」を superview を辿って判定するのに使う
/// （ジェネリッククラスは外から `is PreviewFocusHostingView<...>` で型判定できないため）。
protocol PreviewFocusHostingMarker: AnyObject {}

/// プレビューペインのフォーカス判定。
enum PreviewFocus {
    /// `window`（既定は key window）の first responder がプレビューペイン
    /// （検索バーの入力欄・WKWebView 等を含む）配下か。ターミナルやファイルツリーにフォーカスがあるときは false。
    /// 検索バーの TextField は NSTextField 由来で、フォーカス時の first responder は field editor
    /// (NSTextView) になるが、これは NSTextField の subview なので superview を辿れば届く。
    @MainActor
    static func isFirstResponderWithinPreview(in window: NSWindow? = NSApp.keyWindow) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        var view: NSView? = responder
        while let current = view {
            if current is PreviewFocusHostingMarker { return true }
            view = current.superview
        }
        return false
    }
}

/// NSHostingView を継承して Cmd+W / Esc をフォーカスゲート付きで捕捉する。
/// 「self または配下 descendant が first responder のときだけ」発火する。
final class PreviewFocusHostingView<Content: View>: NSHostingView<Content>, PreviewFocusHostingMarker {
    var onClose: () -> Void = {}

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // mount 直後にフォーカスを自分で受ける（ツリーから選択でプレビューが開いたとき、
        // 自然にプレビュー側にフォーカスが渡るように）。
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            // 既に配下の何か（WKWebView 等）が first responder ならそのまま。
            // first responder がプレビュー外なら奪う。
            if let current = window.firstResponder as? NSView, current.isDescendant(of: self) {
                return
            }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // プレビュー内クリック時にフォーカスを移す。descendant が既に持っていれば何もしない。
        if let window = window {
            if let current = window.firstResponder as? NSView, current.isDescendant(of: self) {
                // OK
            } else {
                window.makeFirstResponder(self)
            }
        }
        super.mouseDown(with: event)
    }

    /// self または配下 descendant が first responder か。
    /// WKWebView / PDFView / NSImageView 等がフォーカスを取った場合も「プレビューにフォーカスあり」
    /// とみなす（self だけ見ると効かないケースが出る）。
    private func isFocusedWithin() -> Bool {
        guard let window = window,
              let responder = window.firstResponder as? NSView else { return false }
        if responder === self { return true }
        return responder.isDescendant(of: self)
    }

    /// Cmd+W: プレビュー配下にフォーカスがあるときだけ捕捉。それ以外は responder chain に流す
    /// （= Ghostty が terminal tab close として受ける）。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 13 = W
        if mods == .command, event.keyCode == 13, isFocusedWithin() {
            onClose()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc: cancelOperation は responder chain 経由で来る。プレビュー外にフォーカスがあれば
    /// そもそも呼ばれないが、念のため `isFocusedWithin()` で確認する。
    override func cancelOperation(_ sender: Any?) {
        if isFocusedWithin() {
            onClose()
        }
    }
}
