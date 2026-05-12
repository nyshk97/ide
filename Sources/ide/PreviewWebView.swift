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
    /// マークダウン内の相対リンクを解決するための基点ディレクトリ。
    /// JS 側で <base href> として注入することで、`./foo.md` 等が file://<dir>/foo.md に展開される。
    var baseURL: URL? = nil
    /// 同一プレビューで開いてよいローカルファイルの上限ディレクトリ（= プロジェクトルート）。
    /// これより外の file:// リンクはプレビューに渡さず、コピー + トーストにする
    /// （untrusted Markdown からプロジェクト外を覗かれないように）。nil なら制限しない。
    var allowedRoot: URL? = nil
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

    /// マークダウン内のローカルファイルリンクをクリックされたとき、
    /// 同じプレビューに別ファイルを描画するためのフック。
    /// シングルトンなので、現在表示中の FilePreviewModel を都度差し替える。
    var onNavigateToFile: ((URL) -> Void)?

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
        view.navigationDelegate = self

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
        var dict: [String: Any] = [
            "kind": payload.kind.rawValue,
            "text": payload.text,
            "lang": payload.lang,
            "theme": "auto",
        ]
        if let base = payload.baseURL {
            // 末尾スラッシュが無いと <base> が「ファイル」扱いになるので必ず付与
            var s = base.absoluteString
            if !s.hasSuffix("/") { s += "/" }
            dict["baseHref"] = s
        }
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

    // MARK: - ファイル内検索 (Cmd+F)

    /// `query` にマッチする箇所をすべてハイライトし、最初のマッチへスクロールする。
    /// 戻り値: (マッチ総数, 現在位置 = 1-based / マッチなしは 0)。
    func find(_ query: String) async -> (count: Int, index: Int) {
        await evalFind("(window.viewer && window.viewer.find) ? window.viewer.find(\(Self.jsString(query))) : {count:0,index:0}")
    }

    /// 次（forward=true）/ 前（false）のマッチへ移動する。
    func findNext(forward: Bool) async -> (count: Int, index: Int) {
        await evalFind("(window.viewer && window.viewer.findNext) ? window.viewer.findNext(\(forward)) : {count:0,index:0}")
    }

    /// 現在のハイライト状態（マッチ総数・現在位置）を取得する。コンテンツ再描画後の同期用。
    func findState() async -> (count: Int, index: Int) {
        await evalFind("(window.viewer && window.viewer.findState) ? window.viewer.findState() : {count:0,index:0}")
    }

    /// ハイライトを消す（検索バーを閉じるとき）。
    func clearFind() {
        guard isReady else { return }
        webView.evaluateJavaScript("window.viewer && window.viewer.clearFind && window.viewer.clearFind();", completionHandler: nil)
    }

    private func evalFind(_ js: String) async -> (count: Int, index: Int) {
        guard isReady else { return (0, 0) }
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { result, _ in
                let dict = result as? [String: Any]
                let count = (dict?["count"] as? NSNumber)?.intValue ?? 0
                let index = (dict?["index"] as? NSNumber)?.intValue ?? 0
                cont.resume(returning: (count, index))
            }
        }
    }

    /// 文字列を JS のリテラルとして安全に埋め込む（JSON 文字列 ≒ JS 文字列）。
    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let str = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return str
    }

    /// マークダウン内のリンクが踏まれたときの分岐:
    ///   - `#section` 等の同一文書フラグメント: WebView 側にそのまま流す
    ///   - file:// のローカルパス: cancel して `onNavigateToFile` にディスパッチ
    ///   - http/https/mailto/その他: cancel してクリップボードコピー + info トースト
    fileprivate func handleLinkActivation(_ url: URL) -> WKNavigationActionPolicy {
        // 同一ページ内アンカー (#... のみ) は WebView に任せる
        if url.scheme == "file",
           let viewer = viewerURL,
           url.path == viewer.path,
           url.fragment != nil
        {
            return .allow
        }

        if url.isFileURL {
            if isWithinAllowedRoot(url) {
                onNavigateToFile?(url)
            } else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url.path, forType: .string)
                ErrorBus.shared.notify("プロジェクト外のリンクはコピーしました: \(url.path)", kind: .info)
            }
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(url.absoluteString, forType: .string)
            ErrorBus.shared.notify("URLをコピーしました: \(url.absoluteString)", kind: .info)
        }
        return .cancel
    }

    /// file URL が現在のプレビューの `allowedRoot` 配下か。`allowedRoot` が nil なら無条件で true。
    private func isWithinAllowedRoot(_ url: URL) -> Bool {
        guard let root = lastApplied?.allowedRoot else { return true }
        let rootPath = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
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

extension PreviewWebController: WKNavigationDelegate {
    // WK_SWIFT_UI_ACTOR void (^)(WKNavigationActionPolicy) → @MainActor 付きでないと
    // Optional プロトコル要件に「適合」したと認識されず、実行時に呼ばれない。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(handleLinkActivation(url))
    }
}

/// シングルトンの WKWebView を SwiftUI に流す薄い NSViewRepresentable。
/// 中身は controller が保持し、view 自体はそれを表示するだけ。
struct PreviewWebView: NSViewRepresentable {
    let payload: PreviewPayload
    var onLinkToFile: ((URL) -> Void)? = nil
    var controller: PreviewWebController = .shared

    func makeNSView(context: Context) -> WKWebView {
        controller.onNavigateToFile = onLinkToFile
        controller.set(payload)
        return controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        controller.onNavigateToFile = onLinkToFile
        controller.set(payload)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        // シングルトンなので破棄しない。SwiftUI 側で作り直されても WebView は再利用。
    }
}
