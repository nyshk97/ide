import SwiftUI
import GhosttyKit
import Sparkle

@main
struct PolePoleApp: App {
    // メインメニューの実行時整理（AppKit が動的に足す項目の除去）。
    @NSApplicationDelegateAdaptor(PolePoleAppDelegate.self) private var appDelegate

    // Sparkle の updater controller。`startingUpdater: true` で起動時に Sparkle 本体が
    // 立ち上がるが、Info.plist で SUEnableAutomaticChecks=false にしてあるので、
    // ネットワークアクセスはメニューを押した時だけ走る。
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init() {
        // XCTest 実行時（unit test の TEST_HOST 経由）は重い初期化を全部 skip する。
        // Ghostty / Sparkle / WebView prewarm / license check は test には不要 + 副作用が大きい。
        // `XCTestConfigurationFilePath` は XCTest runner が必ずセットする env。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        Logger.shared.resetDebugMirror()
        GhosttyManager.shared.start()
        MRUKeyMonitor.install()
        // ファイルプレビュー用 WKWebView を pre-warm。起動時に
        // 1 度ロードしておくと、最初のクリックから表示までを短縮できる。
        PreviewWebController.shared.prewarm()
        // クリップボード画像キャッシュの古いもの（1 日以上前）を掃除する。
        cleanupOldClipboardImages()
        // トライアル残り 7 日以下で menu bar 警告アイコンを表示する。
        MainActor.assumeIsolated {
            LicenseMenuBarController.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 500)
                .preferredColorScheme(.dark)
        }
        .commands {
            // ---- PolePole (app) メニュー ----
            // About と Quit の間に Check for Updates… と ログファイルを開く。
            // 「ログファイルを開く」は元 Help メニューにあったが、Help の検索ボックスを
            // 確実に消す手段が無かったため Help メニュー自体を AppDelegate で削除し、
            // この項目だけ PolePole Dev メニューへ移した。
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
                Divider()
                Button("Open Log Folder") {
                    let url = Logger.shared.directory
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .keyboardShortcut("L", modifiers: [.command, .shift])
            }
            // Services を消す
            CommandGroup(replacing: .systemServices) { }
            // Hide PolePole / Hide Others / Show All を消す
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
            // 中身は PolePole Help だけ残るが Search ボックスを SwiftUI/AppKit からは
            // 消せないため、メニュー自体を AppDelegate でまるごと削除する。
            CommandGroup(replacing: .help) { }
        }

        // ---- PolePole > Settings… (Cmd+,) ----
        // Settings シーンを宣言するとアプリメニューに自動で "Settings…" が追加され、
        // Cmd+, で開ける。Shortcuts と License の 2 タブ構成。
        Settings {
            TabView {
                ShortcutsSettingsView()
                    .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                ImportSettingsView()
                    .tabItem { Label("Import", systemImage: "tray.and.arrow.down") }
                LicenseSettingsView()
                    .tabItem { Label("License", systemImage: "checkmark.seal") }
            }
            .preferredColorScheme(.dark)
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
