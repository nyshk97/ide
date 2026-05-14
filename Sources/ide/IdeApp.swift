import SwiftUI
import GhosttyKit
import Sparkle

@main
struct IdeApp: App {
    // メインメニューの実行時整理（AppKit が動的に足す項目の除去）。
    @NSApplicationDelegateAdaptor(IdeAppDelegate.self) private var appDelegate

    // Sparkle の updater controller。`startingUpdater: true` で起動時に Sparkle 本体が
    // 立ち上がるが、Info.plist で SUEnableAutomaticChecks=false にしてあるので、
    // ネットワークアクセスはメニューを押した時だけ走る。
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        Logger.shared.resetDebugMirror()
        GhosttyManager.shared.start()
        MRUKeyMonitor.install()
        // ファイルプレビュー用 WKWebView を pre-warm。起動時に
        // 1 度ロードしておくと、最初のクリックから表示までを短縮できる。
        PreviewWebController.shared.prewarm()
        // クリップボード画像キャッシュの古いもの（1 日以上前）を掃除する。
        cleanupOldClipboardImages()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 500)
        }
        .commands {
            // ---- IDE (app) メニュー ----
            // About と Quit の間に Check for Updates… と 最近のログを開く。
            // 「最近のログを開く」は元 Help メニューにあったが、Help の検索ボックスを
            // 確実に消す手段が無かったため Help メニュー自体を AppDelegate で削除し、
            // この項目だけ IDE Dev メニューへ移した。
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                Divider()
                Button("最近のログを開く") {
                    let url = Logger.shared.directory
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
            }
            // Services を消す
            CommandGroup(replacing: .systemServices) { }
            // Hide IDE / Hide Others / Show All を消す
            CommandGroup(replacing: .appVisibility) { }

            // ---- File メニュー ----
            // New Window を消す（File メニュー自体は AppDelegate で削除）
            CommandGroup(replacing: .newItem) { }

            // ---- Edit メニュー ----
            // Undo / Redo を消す（Cut/Copy/Paste/Delete/Select All は残す）
            CommandGroup(replacing: .undoRedo) { }

            // ---- Window メニュー ----
            // 中身を空に（Window メニュー自体は AppDelegate で削除）
            CommandGroup(replacing: .windowSize) { }
            CommandGroup(replacing: .windowArrangement) { }
            CommandGroup(replacing: .windowList) { }

            // ---- Help メニュー ----
            // 中身は IDE Help だけ残るが Search ボックスを SwiftUI/AppKit からは
            // 消せないため、メニュー自体を AppDelegate でまるごと削除する。
            CommandGroup(replacing: .help) { }
        }
    }
}

/// Sparkle のサンプル準拠。`canCheckForUpdates` を KVO で追って、
/// 進行中はメニューを disabled にする。
private struct CheckForUpdatesView: View {
    @ObservedObject private var checker: UpdaterChecker
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.checker = UpdaterChecker(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!checker.canCheckForUpdates)
    }
}

@MainActor
private final class UpdaterChecker: ObservableObject {
    @Published var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }
}
