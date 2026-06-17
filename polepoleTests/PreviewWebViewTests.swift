import AppKit
import WebKit
import XCTest
@testable import polepole

@MainActor
final class PreviewWebViewTests: XCTestCase {
    func testMarkdownLocalLinkPostsLinkActivatedBeforeWebKitNavigation() throws {
        let probe = WebKitProbe()
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(probe, name: "viewerReady")
        userContent.add(probe, name: "linkActivated")
        config.userContentController = userContent

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = probe
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        window.contentView = webView
        window.orderFront(nil)

        let viewer = try XCTUnwrap(
            Bundle.main.url(forResource: "viewer", withExtension: "html", subdirectory: "preview")
        )
        probe.readyExpectation = expectation(description: "viewerReady")
        webView.loadFileURL(viewer, allowingReadAccessTo: viewer.deletingLastPathComponent())
        wait(for: [try XCTUnwrap(probe.readyExpectation)], timeout: 8.0)

        let payload: [String: Any] = [
            "kind": "markdown",
            "text": "[こちら](./docs/clifor-auth.md)",
            "lang": "",
            "theme": "auto",
            "preserveScroll": false,
            "baseHref": "file:///Users/d0ne1s/lw/lincwell/",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        try evaluate("window.viewer.set(\(json));", in: webView)
        probe.activatedExpectation = expectation(description: "linkActivated")
        try evaluate("""
        document.querySelector('a').dispatchEvent(
          new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 })
        );
        """, in: webView)
        wait(for: [try XCTUnwrap(probe.activatedExpectation)], timeout: 2.0)

        XCTAssertEqual(probe.activatedURL, "file:///Users/d0ne1s/lw/lincwell/docs/clifor-auth.md")
        XCTAssertNil(probe.navigationURL, "JS should intercept markdown links before WebKit navigation")
    }

    private func evaluate(_ js: String, in webView: WKWebView) throws {
        let exp = expectation(description: "evaluateJavaScript")
        var capturedError: Error?
        webView.evaluateJavaScript(js) { value, error in
            _ = value
            capturedError = error
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        if let capturedError {
            throw capturedError
        }
    }
}

private final class WebKitProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var readyExpectation: XCTestExpectation?
    var activatedExpectation: XCTestExpectation?
    var activatedURL: String?
    var navigationURL: String?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "viewerReady" {
            readyExpectation?.fulfill()
        } else if message.name == "linkActivated" {
            activatedURL = message.body as? String
            activatedExpectation?.fulfill()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated {
            navigationURL = navigationAction.request.url?.absoluteString
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
