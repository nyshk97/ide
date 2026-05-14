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
        if len > 0 {
            return String(cString: buffer)
        }
        // proc_pidpath が失敗するケースに備えたフォールバック。
        // 実例: claude code は bun の SEA（single executable）バイナリで、
        // 起動後の executable path が kernel から取れず proc_pidpath が 0 を返す。
        // kinfo_proc.kp_proc.p_comm は basename のみ（16 文字制限）だが、classify() は
        // lastPathComponent しか見ないので path として返しても問題ない。
        return procComm(for: pid)
    }

    /// `sysctl KERN_PROC_PID` で kinfo_proc を取って `p_comm` を返す。
    /// p_comm はカーネルが記録するプロセス名で 16 文字に切り詰められうるが、
    /// `claude.exe` や `codex` 程度の名前なら丸ごと収まる。
    private static func procComm(for pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard r == 0 else { return nil }
        let comm = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return comm.isEmpty ? nil : comm
    }
}
