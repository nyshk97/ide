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
        // Homebrew cask 配布の codex は `codex-aarch64-apple-darwin` 等の triple 付き名で
        // 入っており、`/opt/homebrew/bin/codex` はそこへの symlink。proc_pidpath は実体を返すので
        // basename を prefix で判定する。
        if baseNoExt == "codex" || baseNoExt.hasPrefix("codex-") {
            return .codex
        }
        switch baseNoExt {
        case "claude":
            return .claude
        case "zsh", "bash", "fish", "sh", "dash":
            return .shell
        case "node", "bun", "deno", "python", "python3", "ruby":
            // 汎用 interpreter (`node` 等) が fg のときは argv を見て AI ツールか判定。
            // npm 経由でグローバルインストールされた claude は `/usr/bin/env node /path/to/cli.js`
            // のような起動で、fg プロセス名が `node` になる。argv[1] に script のパスが入るので、
            // そこに `claude-code` / `@anthropic-ai/claude-code` 等が含まれていれば claude とみなす。
            if let args = procArgs(for: pid), let kind = classifyFromArgs(args) {
                return kind
            }
            return .other(base)
        default:
            return .other(base)
        }
    }

    /// `procArgs()` で取得した argv 配列から AI ツールを推定する。
    /// 各 argv をすべてスキャンし、最初にマッチした種別を返す。マッチしなければ nil。
    ///
    /// substring match は広すぎる（`claude-code-review` のような別ツール / `node -e` の
    /// eval ソース等を誤って拾う）ので、各 argv を path component に分割して **component
    /// 完全一致** で判定する。例:
    /// - npm global path: `~/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js`
    ///   → `["@anthropic-ai", "claude-code"]` が隣接する component として一致
    /// - shim: `/usr/local/bin/claude` → basename が `claude`
    private static func classifyFromArgs(_ args: [String]) -> TerminalTab.ForegroundProgram? {
        for raw in args {
            let lower = raw.lowercased()
            let components = lower.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let basename = components.last ?? ""

            // Claude Code
            if Self.claudeBasenames.contains(basename)
                || Self.hasAdjacentComponents(components, "@anthropic-ai", "claude-code") {
                return .claude
            }
            // Codex CLI (OpenAI)
            if Self.codexBasenames.contains(basename)
                || Self.hasAdjacentComponents(components, "@openai", "codex")
                || Self.hasAdjacentComponents(components, "@openai", "codex-cli") {
                return .codex
            }
        }
        return nil
    }

    private static let claudeBasenames: Set<String> = [
        "claude", "claude.js", "claude.mjs", "claude.exe",
        "claude-code", "claude-code.js", "claude-code.mjs",
    ]

    private static let codexBasenames: Set<String> = [
        "codex", "codex.js", "codex.mjs",
        "codex-cli", "codex-cli.js", "codex-cli.mjs",
    ]

    /// `components` の中で `a, b` の順に隣接する 2 要素があるか。
    /// 例: `["lib", "node_modules", "@anthropic-ai", "claude-code", "cli.js"]` に対して
    /// `("@anthropic-ai", "claude-code")` → true。
    private static func hasAdjacentComponents(_ components: [String], _ a: String, _ b: String) -> Bool {
        guard components.count >= 2 else { return false }
        for i in 0..<(components.count - 1) where components[i] == a && components[i + 1] == b {
            return true
        }
        return false
    }

    /// `sysctl KERN_PROCARGS2` で対象 PID の argv を取得する。失敗時は nil。
    ///
    /// macOS の KERN_PROCARGS2 バッファは以下のレイアウト:
    /// `[argc: Int32][exec_path: cstring][NUL padding][argv[0]: cstring]...[argv[argc-1]][envp...]`
    ///
    /// 同じユーザーが起動したプロセスなら権限なしで読める。
    ///
    /// 既知の制約: `exec_path` と `argv[0]` の間の NUL padding は単純に「連続する \0
    /// を全部スキップ」している。これだと **`argv[0]` が空文字 ("")** の極めて稀なケース
    /// では padding と区別できず argv[0] を取り損なう。実際の Claude/Codex 系の起動経路
    /// では argv[0] は常に exec path 文字列が入るため、この制約は許容している。
    static func procArgs(for pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        // 1 回目: 必要バッファサイズの問い合わせ
        if sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) != 0 || size <= MemoryLayout<Int32>.size {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        // 2 回目: 実データを取得
        let r = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            sysctl(&mib, UInt32(mib.count), ptr.baseAddress, &size, nil, 0)
        }
        guard r == 0 else { return nil }

        // 先頭 4 バイト = argc
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        // exec_path 部分（最初の cstring）をスキップ
        var offset = MemoryLayout<Int32>.size
        while offset < size, buffer[offset] != 0 { offset += 1 }
        // exec_path の終端 NUL + 後続 padding NUL を全部スキップして argv[0] の先頭へ。
        // ※ argv[0] が空文字のケースは区別できない（上記コメント参照）。
        while offset < size, buffer[offset] == 0 { offset += 1 }

        // argv を argc 個読む。**空文字の argv も 1 要素として数える** ことが重要。
        // 数え漏らすと argc に達するまでループが続いて、後続の envp 領域まで読み進んで
        // しまう（環境変数文字列を argv と誤って解釈して classifyFromArgs に渡ることになる）。
        var args: [String] = []
        args.reserveCapacity(Int(argc))
        for _ in 0..<Int(argc) {
            guard offset < size else { break }
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            let slice = buffer[start..<offset]
            args.append(String(bytes: slice, encoding: .utf8) ?? "")
            offset += 1 // 終端 NUL を飛ばして次の文字列の先頭へ
        }
        return args.isEmpty ? nil : args
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
