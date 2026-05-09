import SwiftUI
import GhosttyKit

@main
struct IdeApp: App {
    init() {
        PocLog.reset()
        GhosttyManager.shared.start()
        MRUKeyMonitor.install()
        // ファイルプレビュー用 WKWebView を pre-warm。起動時に
        // 1 度ロードしておくと、最初のクリックから表示までを短縮できる。
        PreviewWebController.shared.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 500)
        }
        .commands {
            // メニュー > Help > 最近のログを開く
            CommandGroup(after: .help) {
                Button("最近のログを開く") {
                    let url = Logger.shared.directory
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
            }
        }
    }
}
