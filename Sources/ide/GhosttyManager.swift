import AppKit
import GhosttyKit

final class GhosttyManager: @unchecked Sendable {
    static let shared = GhosttyManager()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    /// クリップボード等で使う「現在フォーカスのある surface」。
    /// becomeFirstResponder のたびに切替わる。
    private(set) var activeSurface: ghostty_surface_t?

    /// surface ハンドルから所属タブを逆引きするための弱参照マップ。
    /// SHOW_CHILD_EXITED action で exit code をタブに反映するのに使う。
    private var surfaceToTab: [ghostty_surface_t: WeakTabRef] = [:]

    /// foreground プロセスを polling するタイマー。
    private var foregroundPollTimer: Timer?

    private final class WeakTabRef {
        weak var value: TerminalTab?
        init(_ tab: TerminalTab) { self.value = tab }
    }

    func register(surface: ghostty_surface_t, tab: TerminalTab) {
        activeSurface = surface
        surfaceToTab[surface] = WeakTabRef(tab)
    }

    func unregister(surface: ghostty_surface_t) {
        if activeSurface == surface {
            activeSurface = nil
        }
        surfaceToTab.removeValue(forKey: surface)
    }

    func tab(forSurface surface: ghostty_surface_t) -> TerminalTab? {
        surfaceToTab[surface]?.value
    }

    /// 全 surface の foreground プロセスを 500ms ごとに識別し、変化があればタブに反映。
    private func startForegroundPolling() {
        foregroundPollTimer?.invalidate()
        foregroundPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                GhosttyManager.shared.tickForegroundPolling()
            }
        }
    }

    @MainActor
    private func tickForegroundPolling() {
        // 死んだ参照は除去
        surfaceToTab = surfaceToTab.filter { $0.value.value != nil }

        for (surface, ref) in surfaceToTab {
            guard let tab = ref.value else { continue }
            let pid = ghostty_surface_foreground_pid(surface)
            let program = ForegroundProcessInspector.classify(pid: pid_t(pid))
            #if DEBUG
            if tab.foregroundProgram != program {
                let path = ForegroundProcessInspector.executablePath(for: pid_t(pid)) ?? "(nil)"
                PocLog.write("[fg] tab=\(tab.title) pid=\(pid) path=\(path) -> \(program)")
            }
            #endif
            if tab.foregroundProgram != program {
                tab.foregroundProgram = program
            }
        }
    }

    private init() {}

    func start() {
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        let info = ghostty_info()
        let version = info.version.map { String(cString: $0) } ?? "(nil)"
        PocLog.write("[ghostty] init=\(result) version=\(version) build_mode=\(info.build_mode.rawValue)")
        guard result == GHOSTTY_SUCCESS else { return }

        guard let cfg = ghostty_config_new() else {
            PocLog.write("[ghostty] config_new returned nil")
            return
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        let diagCount = ghostty_config_diagnostics_count(cfg)
        PocLog.write("[ghostty] config diagnostics: \(diagCount)")
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                PocLog.write("[ghostty]   diag[\(i)]: \(String(cString: msg))")
            }
        }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in
            DispatchQueue.main.async {
                if let app = GhosttyManager.shared.app {
                    ghostty_app_tick(app)
                }
            }
        }
        runtime.action_cb = { _, target, action in
            switch action.tag {
            case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                if target.tag == GHOSTTY_TARGET_SURFACE,
                   let surface = target.target.surface {
                    let code = action.action.child_exited.exit_code
                    DispatchQueue.main.async {
                        if let tab = GhosttyManager.shared.tab(forSurface: surface) {
                            tab.lifecycle = .exited(code: code)
                        }
                    }
                }
            case GHOSTTY_ACTION_RING_BELL:
                if target.tag == GHOSTTY_TARGET_SURFACE,
                   let surface = target.target.surface {
                    DispatchQueue.main.async {
                        if let tab = GhosttyManager.shared.tab(forSurface: surface),
                           !WorkspaceModel.shared.isCurrentlyActive(tab: tab) {
                            tab.hasUnreadNotification = true
                        }
                    }
                }
            default:
                break
            }
            return true
        }
        runtime.read_clipboard_cb = ghosttyReadClipboardCallback
        runtime.confirm_read_clipboard_cb = ghosttyConfirmReadClipboardCallback
        runtime.write_clipboard_cb = ghosttyWriteClipboardCallback
        runtime.close_surface_cb = { _, _ in }

        guard let appHandle = ghostty_app_new(&runtime, cfg) else {
            PocLog.write("[ghostty] app_new returned nil")
            ghostty_config_free(cfg)
            return
        }
        self.app = appHandle
        self.config = cfg
        PocLog.write("[ghostty] app_new ok")

        // foreground プロセス監視を開始
        startForegroundPolling()

        // フォーカス連動
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            if let app = GhosttyManager.shared.app {
                ghostty_app_set_focus(app, true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { _ in
            if let app = GhosttyManager.shared.app {
                ghostty_app_set_focus(app, false)
            }
        }
    }
}
