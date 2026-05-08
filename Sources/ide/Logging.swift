import Foundation

enum PocLog {
    static let path = "/tmp/ide-poc.log"
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        try? "".write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
    }

    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = message + "\n"
        guard let data = line.data(using: String.Encoding.utf8) else { return }
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: String.Encoding.utf8)
        }
        FileHandle.standardError.write(data)
    }
}
