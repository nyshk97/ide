import Foundation
import Darwin

/// PID → 実行ファイル名 → AI 種別 を解決するユーティリティ。
/// libproc の proc_pidpath で exec path を取得（ps 経由よりも 100 倍程度速い）。
enum ForegroundProcessInspector {
    static func classify(pid: pid_t) -> TerminalTab.ForegroundProgram {
        guard pid > 0, let path = executablePath(for: pid) else { return .shell }
        let base = (path as NSString).lastPathComponent.lowercased()
        // claude は npm の wrapper だと `claude.exe` のことがある（拡張子付き）。
        // 拡張子を取り除いて判定。
        let baseNoExt = (base as NSString).deletingPathExtension
        switch baseNoExt {
        case "claude":
            return .claude
        case "codex", "codex-cli":
            return .codex
        case "zsh", "bash", "fish", "sh", "dash":
            return .shell
        default:
            return .other(base)
        }
    }

    /// `<libproc.h>` の `PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN` 相当
    private static let pathBufferSize: Int = 4096

    static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let len = proc_pidpath(pid, &buffer, UInt32(pathBufferSize))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }
}
