import Foundation

/// シェルにそのまま貼り付けても 1 引数として解釈されるようにエスケープする。
///
/// 以前は `ClipboardSupport` 内のプライベート関数だったが、「ターミナルで開く」の
/// `cd <path>` でも使うので独立させた。
enum ShellEscaper {
    static func escape(_ value: String) -> String {
        // 改行を含むパスはバックスラッシュエスケープでは扱えないので単一引用符で囲む。
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) {
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        let charsToEscape = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var result = value
        for ch in charsToEscape {
            result = result.replacingOccurrences(of: String(ch), with: "\\\(ch)")
        }
        return result
    }
}
