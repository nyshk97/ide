import SwiftUI
import GhosttyKit

@main
struct IdeApp: App {
    init() {
        func log(_ s: String) {
            let line = s + "\n"
            if let data = line.data(using: String.Encoding.utf8) {
                if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/ide-poc.log")) {
                    h.seekToEndOfFile()
                    h.write(data)
                    try? h.close()
                } else {
                    try? line.write(toFile: "/tmp/ide-poc.log", atomically: true, encoding: String.Encoding.utf8)
                }
                FileHandle.standardError.write(data)
            }
        }
        try? "".write(toFile: "/tmp/ide-poc.log", atomically: true, encoding: String.Encoding.utf8)

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        let info = ghostty_info()
        let version: String
        if let cstr = info.version {
            version = String(cString: cstr)
        } else {
            version = "(nil)"
        }
        log("[ide] ghostty_init=\(result) (GHOSTTY_SUCCESS=\(GHOSTTY_SUCCESS)) version=\(version) build_mode=\(info.build_mode.rawValue)")

        guard result == GHOSTTY_SUCCESS else { return }

        log("[ide] before ghostty_config_new")
        guard let cfg = ghostty_config_new() else {
            log("[ide] ghostty_config_new returned nil")
            return
        }
        log("[ide] after ghostty_config_new")
        ghostty_config_load_default_files(cfg)
        log("[ide] after load_default_files")
        ghostty_config_load_recursive_files(cfg)
        log("[ide] after load_recursive_files")
        ghostty_config_finalize(cfg)
        log("[ide] after finalize")
        let diagCount = ghostty_config_diagnostics_count(cfg)
        log("[ide] config diagnostics count: \(diagCount)")
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                log("[ide]   diag[\(i)]: \(String(cString: msg))")
            }
        }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = nil
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { _ in /* TODO: schedule ghostty_app_tick on main */ }
        runtime.action_cb = { _, _, _ in true }
        runtime.read_clipboard_cb = { _, _, _ in false }
        runtime.confirm_read_clipboard_cb = { _, _, _, _ in }
        runtime.write_clipboard_cb = { _, _, _, _, _ in }
        runtime.close_surface_cb = { _, _ in }

        log("[ide] before ghostty_app_new")
        let appHandle = ghostty_app_new(&runtime, cfg)
        log("[ide] after ghostty_app_new = \(appHandle != nil ? "ok" : "nil")")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
