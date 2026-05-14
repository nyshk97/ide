import SwiftUI
import GhosttyKit
import Sparkle

@main
struct IdeApp: App {
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
            // メニュー > IDE > Check for Updates…（About と Quit の間、macOS 標準位置）
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
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
