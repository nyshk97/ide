import Foundation

/// 単一ファイルの変更を監視する。プレビュー中ファイルの自動リロード用。
///
/// kqueue（`DispatchSource` のファイルシステムオブジェクト）はファイルディスクリプタ
/// 単位の監視なので、エディタの「アトミック保存」（temp に書き込み→rename で差し替え）で
/// inode が入れ替わると、握っている fd が古い inode を指したまま以降の write を取りこぼす。
/// そのため delete/rename を検知したら同じパスを開き直して監視を継続する。
///
/// `events(for:)` が返す `AsyncStream` を for-await で消費する想定。消費側の Task が
/// cancel される（= stream が破棄される）と監視も自動で停止する。
enum FileChangeWatcher {
    /// 指定パスの「変更があった」イベントを流す。連続書き込みは ~120ms でまとめる。
    static func events(for url: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let watcher = Watcher(path: url.path) { continuation.yield() }
            continuation.onTermination = { _ in watcher.stop() }
            watcher.start()
        }
    }

    /// 監視の実体。全状態は `queue` 上でのみ触る前提なので `@unchecked Sendable`。
    private final class Watcher: @unchecked Sendable {
        private let path: String
        private let onChange: () -> Void
        private let queue = DispatchQueue(label: "local.d0ne1s.ide.filewatcher")

        private var source: DispatchSourceFileSystemObject?
        private var debounce: DispatchWorkItem?
        private var reopenRetries = 0
        private var stopped = false

        init(path: String, onChange: @escaping () -> Void) {
            self.path = path
            self.onChange = onChange
        }

        func start() {
            queue.async { [weak self] in self?.attach() }
        }

        func stop() {
            queue.async { [weak self] in
                guard let self else { return }
                self.stopped = true
                self.debounce?.cancel()
                self.debounce = nil
                self.source?.cancel()   // cancel handler が fd を閉じる
                self.source = nil
            }
        }

        /// パスを開き直して新しい dispatch source を張る。
        /// ファイルがまだ無いとき（削除→再作成の途中など）は少し待ってリトライする。
        private func attach() {
            guard !stopped else { return }
            source?.cancel()   // 旧 source があれば破棄（cancel handler が旧 fd を閉じる）
            source = nil

            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                guard reopenRetries < 120 else { return }   // ~60s 試して諦める
                reopenRetries += 1
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.attach() }
                return
            }
            reopenRetries = 0

            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename, .revoke],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self, let flags = self.source?.data else { return }
                self.notifyDebounced()
                // inode 差し替え系（アトミック保存・削除）は fd が死んでいるので開き直す
                if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                    self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.attach() }
                }
            }
            src.setCancelHandler { close(fd) }
            source = src
            src.resume()
        }

        private func notifyDebounced() {
            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            debounce = work
            queue.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}
