import SwiftUI
import WebKit

/// プレビュー本体に表示するペイロード。markdown / コード / エラーのみ扱う。
/// 画像・PDF・バイナリは別系統（FilePreviewView 側）でレンダリングする。
struct PreviewPayload: Equatable {
    enum Kind: String { case markdown, code, error }
    let kind: Kind
    let text: String
    /// highlight.js に渡す言語名（拡張子から推定）。空文字なら auto detect。
    let lang: String
}

/// WKWebView を 1 つだけ生成し、初回 viewer.html ロード後は
/// JS 経由で本文だけ差し替えることで「クリック→表示」を高速化する。
@MainActor
final class PreviewWebController: NSObject, ObservableObject {
    static let shared = PreviewWebController()

    let webView: WKWebView

    private var isReady = false
    private var pending: PreviewPayload?
    private var lastApplied: PreviewPayload?

    /// viewer.html / vendor/* を含む blue folder reference のルート URL。
    /// `loadFileURL(_:allowingReadAccessTo:)` で sandbox を絞る用。
    private let resourceRoot: URL?
    private let viewerURL: URL?

    override init() {
        let config = WKWebViewConfiguration()
        // ローカルバンドル内の JS が DOMContentLoaded 後に postMessage("ready") できるように。
        let userController = WKUserContentController()
        config.userContentController = userController

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")  // 背景を本体に合わせる
        if #available(macOS 13.3, *) {
            view.isInspectable = true
        }
        self.webView = view

        let bundle = Bundle.main
        let viewer = bundle.url(forResource: "viewer", withExtension: "html", subdirectory: "preview")
        self.viewerURL = viewer
        self.resourceRoot = viewer?.deletingLastPathComponent()

        super.init()

        userController.add(MessageHandler(owner: self), name: "viewerReady")

        loadTemplate()
    }

    /// テンプレートをロード。アプリ起動時に呼ばれる（pre-warm）。
    func prewarm() {
        // init で既にロードされているので no-op。
        // 呼び出し側からの「明示的に温めたい」シグナルとして残しておく。
        _ = webView
    }

    private func loadTemplate() {
        guard let viewer = viewerURL, let root = resourceRoot else {
            isReady = false
            return
        }
        webView.loadFileURL(viewer, allowingReadAccessTo: root)
    }

    /// 表示内容を更新。テンプレ ready 前に呼ばれた場合は ready 後に適用する。
    func set(_ payload: PreviewPayload) {
        if lastApplied == payload {
            return  // 同一内容ならスキップ（履歴往復で同じファイルに戻ったとき等）
        }
        if !isReady {
            pending = payload
            return
        }
        applyNow(payload)
    }

    fileprivate func handleReady() {
        isReady = true
        if let p = pending {
            pending = nil
            applyNow(p)
        }
    }

    private func applyNow(_ payload: PreviewPayload) {
        lastApplied = payload
        let dict: [String: Any] = [
            "kind": payload.kind.rawValue,
            "text": payload.text,
            "lang": payload.lang,
            "theme": "auto",
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        let js = "window.viewer && window.viewer.set(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// プレビューを閉じるときなどに本文をクリアする。
    func clear() {
        lastApplied = nil
        guard isReady else { return }
        webView.evaluateJavaScript("document.getElementById('root').innerHTML = '';", completionHandler: nil)
    }

    /// JS から ready 通知を受け取るための薄いブリッジ。
    /// WKScriptMessageHandler を NSObject 継承で持たせると WebView が
    /// PreviewWebController を強参照してしまうため、weak で握る別オブジェクトに分離。
    private final class MessageHandler: NSObject, WKScriptMessageHandler {
        weak var owner: PreviewWebController?
        init(owner: PreviewWebController) {
            self.owner = owner
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "viewerReady" {
                Task { @MainActor in self.owner?.handleReady() }
            }
        }
    }
}

/// シングルトンの WKWebView を SwiftUI に流す薄い NSViewRepresentable。
/// 中身は controller が保持し、view 自体はそれを表示するだけ。
struct PreviewWebView: NSViewRepresentable {
    let payload: PreviewPayload
    var controller: PreviewWebController = .shared

    func makeNSView(context: Context) -> WKWebView {
        controller.set(payload)
        return controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        controller.set(payload)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        // シングルトンなので破棄しない。SwiftUI 側で作り直されても WebView は再利用。
    }
}
