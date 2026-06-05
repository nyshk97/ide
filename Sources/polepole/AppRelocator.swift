import AppKit
import Foundation

/// 起動時に「アプリがダウンロード場所から実行されていないか」を確認し、もしそうなら
/// `/Applications` へ移動してから再起動する（LetsMove / PFMoveApplication 相当）。
///
/// ## なぜ必要か
/// macOS は quarantine 属性 (`com.apple.quarantine`) の付いた `.app` を、Finder で
/// `/Applications` へドラッグ移動せずに起動すると、**App Translocation**
/// (Gatekeeper Path Randomization) により読み取り専用のランダムパス
/// (`/private/var/folders/.../AppTranslocation/<rand>/d/PolePole.app`) にマウントして実行する。
/// Sparkle はこのパスを検出して自己アップデートを拒否する (`SURunningTranslocated`)。
///
/// → DMG をマウントして中身を直接ダブルクリック起動した（= Applications にドラッグしていない）
///   ユーザーの環境で「PolePole can't be updated if it's running from the location it was
///   downloaded to.」が出る。本人 (`/Applications` 実体 or brew 経由 = quarantine なし) では
///   再現しないので「コードのバグ」ではなく「配布物の受け取り方」の問題。
///
/// 初回起動時に Applications へ自動移動して quarantine を剥がすことで恒久的に解決する。
@MainActor
enum AppRelocator {
    /// 検証用フラグ。`"alert"` = dry-run（判定 + 確認ダイアログだけ出し、実際の移動はしない）。
    /// `"move"` / その他の非空値 = 実際の移動まで実行する（通常は使わない）。
    private static let forceEnv = "POLEPOLE_TEST_FORCE_RELOCATE"

    static func relocateIfNeeded() {
        let forced = ProcessInfo.processInfo.environment[forceEnv]
        #if DEBUG
        // Dev ビルドは DerivedData（= Applications 外）から起動するため、毎回ダイアログが出ると
        // 開発の邪魔になる。Debug では強制フラグ指定時のみ動かす。Release は常に有効。
        guard forced != nil else { return }
        #endif

        let bundleURL = Bundle.main.bundleURL
        let translocated = isTranslocated(bundleURL)
        // translocation 時、bundleURL はランダムな読み取り専用パス。元の実体パスへ解決する。
        let sourceURL = (translocated ? originalPath(bundleURL) : nil) ?? bundleURL
        let dryRun = (forced == "alert")

        // 正常系: translocation でなく、実体が Applications 配下 → 何もしない。
        if forced == nil, !translocated, isInApplications(sourceURL) {
            return
        }

        let appName = bundleURL.lastPathComponent // "PolePole.app" / "PolePole Dev.app"
        let destURL = URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
        let destPath = destURL.standardizedFileURL.path
        let sourcePath = sourceURL.standardizedFileURL.path

        Logger.shared.info(
            "[relocate] bundle=\(bundleURL.path) translocated=\(translocated) source=\(sourcePath) dest=\(destPath)"
        )

        // dry-run: 確認ダイアログだけ出して通常起動を続行（検証用）。
        if dryRun {
            _ = presentMoveAlert()
            Logger.shared.info("[relocate] dry-run: 実移動はスキップ")
            return
        }

        // ケース A: 実体が既に dest（Applications 配下の正規の場所）にある
        //   → quarantine が残って translocation しているだけ。quarantine を剥がして dest から relaunch。
        if sourcePath == destPath {
            Logger.shared.info("[relocate] source == dest; dropping quarantine and relaunching")
            removeQuarantine(at: destURL)
            relaunch(at: destURL)
            return
        }

        // ケース B: dest に別の既存インストールがある（brew symlink / 別バージョン等）
        //   → 上書きせずそちらを起動して自分は終了する。
        if FileManager.default.fileExists(atPath: destURL.path) {
            Logger.shared.info("[relocate] dest already exists; launching it instead")
            relaunch(at: destURL)
            return
        }

        // ケース C: DMG / Downloads から起動 → Applications へ移動するか確認。
        guard presentMoveAlert() else {
            Logger.shared.info("[relocate] user declined move; continuing in place")
            return
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Logger.shared.error("[relocate] copy failed: \(error.localizedDescription)")
            presentManualMoveAlert()
            return // 移動できなかったが、そのまま起動はさせる
        }
        removeQuarantine(at: destURL)
        // 元実体を trash（DMG read-only 等で失敗するケースは無視。アンマウントで消える）。
        try? FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
        Logger.shared.info("[relocate] moved to \(destPath); relaunching")
        relaunch(at: destURL)
    }

    // MARK: - 判定

    private static func isInApplications(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/Applications/") { return true }
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").standardizedFileURL.path
        return path.hasPrefix(userApps + "/")
    }

    // MARK: - App Translocation API (Security.framework, dlsym で動的解決)
    //
    // SecTranslocate* は SDK によってはリンク時シンボルとして見えないため、PFMoveApplication と
    // 同様に dlsym で解決する。translocation 自体 macOS 10.12+ の機能なので、シンボルが無い環境
    // (= translocation しない) では false を返せば良い。

    private typealias IsTranslocatedFn =
        @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPathFn =
        @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(nil, RTLD_LAZY), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private static func isTranslocated(_ url: URL) -> Bool {
        guard let fn = symbol("SecTranslocateIsTranslocatedURL", as: IsTranslocatedFn.self) else {
            return false
        }
        var result = false
        var err: Unmanaged<CFError>?
        let ok = fn(url as CFURL, &result, &err)
        err?.release()
        return ok && result
    }

    private static func originalPath(_ url: URL) -> URL? {
        guard let fn = symbol("SecTranslocateCreateOriginalPathForURL", as: OriginalPathFn.self) else {
            return nil
        }
        var err: Unmanaged<CFError>?
        let created = fn(url as CFURL, &err)
        err?.release()
        return created?.takeRetainedValue() as URL?
    }

    // MARK: - 副作用

    private static func removeQuarantine(at url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? task.run()
        task.waitUntilExit()
    }

    /// 現プロセスの終了を待ってから dest を開き直す helper を spawn し、自身を即終了する。
    private static func relaunch(at url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let quoted = shellQuote(url.path)
        let script = "(while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.1; done; /usr/bin/open \(quoted)) &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        exit(0)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - ダイアログ

    /// 戻り値 true = 移動する。
    private static func presentMoveAlert() -> Bool {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PolePole をアプリケーションフォルダに移動しますか?"
        alert.informativeText = """
        PolePole がダウンロード場所（DMG やダウンロードフォルダ）から実行されているため、自動アップデートを適用できません。
        アプリケーションフォルダに移動すると、今後の更新が正しく適用されます。
        """
        alert.addButton(withTitle: "移動して再起動")
        alert.addButton(withTitle: "今はしない")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func presentManualMoveAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "アプリケーションフォルダへ移動できませんでした"
        alert.informativeText = "PolePole を手動でアプリケーションフォルダにドラッグして移動し、そこから起動し直してください。"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
