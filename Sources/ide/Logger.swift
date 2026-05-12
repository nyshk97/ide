import Foundation

/// IDE 全体のログ出力。
///
/// - 永続化: `~/Library/Logs/{ide,ide-dev}/{ide,ide-dev}-YYYY-MM-DD.log`
/// - 日次でファイルが切り替わる
/// - 上限 50MB を超えたら古いログから削除（最大 7 日分まで残す）
/// - error / warn / info / debug の 4 段階
/// - Debug ビルドでは `/tmp/ide-poc.log` にもミラーする（`tail -f` で追える、VERIFY 用）
final class Logger: @unchecked Sendable {
    enum Level: String {
        case error = "ERROR"
        case warn  = "WARN "
        case info  = "INFO "
        case debug = "DEBUG"
    }

    static let shared = Logger()

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let dateFormatter: DateFormatter
    private let lineFormatter: DateFormatter

    private init() {
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(identifier: "UTC")
        self.dateFormatter = date

        let line = DateFormatter()
        line.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        line.locale = Locale(identifier: "en_US_POSIX")
        self.lineFormatter = line

        rotateIfNeeded()
    }

    var directory: URL {
        let logs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(AppPaths.subdirName, isDirectory: true)
        return logs
    }

    private var currentFileURL: URL {
        let dateStr = dateFormatter.string(from: .now)
        return directory.appendingPathComponent("\(AppPaths.subdirName)-\(dateStr).log")
    }

    func error(_ message: String) { write(.error, message) }
    func warn (_ message: String) { write(.warn,  message) }
    func info (_ message: String) { write(.info,  message) }
    func debug(_ message: String) { write(.debug, message) }

    func write(_ level: Level, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let timestamp = lineFormatter.string(from: .now)
        let line = "\(timestamp) [\(level.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = currentFileURL
        if fileManager.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        } else {
            try? data.write(to: url)
        }
        // ターミナル/console 用にも出す
        FileHandle.standardError.write(data)
        #if DEBUG
        appendToDebugMirror(data)
        #endif
    }

    // MARK: - Debug ミラー（/tmp/ide-poc.log）

    #if DEBUG
    private static let debugMirrorPath = "/tmp/ide-poc.log"

    private func appendToDebugMirror(_ data: Data) {
        let url = URL(fileURLWithPath: Self.debugMirrorPath)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
    #endif

    /// 起動時に Debug ミラーを空にする（Release では no-op）。
    func resetDebugMirror() {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        try? Data().write(to: URL(fileURLWithPath: Self.debugMirrorPath))
        #endif
    }

    /// 古いログのクリーンアップ。50MB 超 or 7 日より古いもの。
    private func rotateIfNeeded() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: []
        ) else { return }

        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        var totalSize: Int64 = 0
        let sorted = entries.sorted {
            (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast)
                ?? .distantPast
            >
            (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast)
                ?? .distantPast
        }
        for url in sorted {
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let size = Int64(attrs?.fileSize ?? 0)
            let created = attrs?.creationDate ?? .distantPast
            totalSize += size
            if created < cutoff || totalSize > 50 * 1024 * 1024 {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
