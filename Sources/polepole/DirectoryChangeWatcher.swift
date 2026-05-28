import CoreServices
import Foundation

/// プロジェクト root を再帰的に監視し、ファイルシステム変更があれば `onChange` を呼ぶ。
///
/// 過去 (`docs/plans/phase2-files.md:329`) に GitStatusModel との FSEvents 統合で
/// silent crash した経緯があるため、設計は次の制約に従う:
///
/// - `kFSEventStreamCreateFlagUseCFTypes` を必ず付ける。callback の `eventPaths` は
///   default だと `void *` の C string array で Swift から扱うとクラッシュしやすい
/// - **FSEventStreamContext の retain/release を実装** して self を strong ref として
///   FSEvents に渡す。これで in-flight callback が解放済み self を `takeUnretainedValue`
///   する race を防げる
/// - **`stop()` は明示 API として用意**: `queue.sync` で in-flight callback を drain
///   してから `FSEventStreamStop` / `Invalidate` / `Release`。FSEventStreamRelease が
///   context.release を呼んで FSEvents 側の strong ref を落とす
/// - **`start()` も `queue.sync`**: 「stream 開始 → initial rebuild」の順序を保証する
///   (`queue.async` だと initial rebuild が stream 開始より先に走る race がある)
/// - per-path filter は `.git/` のみ。`IgnoredDirectories` 配下 (node_modules / .build
///   など) は filter しない: gitignore に従って scanViaGit が entries から除外する
///   ため、rebuild の発火だけ抑えても scan 自体は cheap なので意味がない。むしろ
///   「rebuild 自体は走るが scan 結果が変わらない」ほうが scan/watch の対象が一致する
/// - 判定は `path components` ベース。文字列 `contains(".git")` だと `.github` が誤判定
///
/// `minRebuildInterval` (rebuild の最短間隔制御) は **このクラスには持たない**。
/// FileIndex は完了タイミングを知っているので、そちら側で管理する。
final class DirectoryChangeWatcher: @unchecked Sendable {
    private let root: URL
    private let rootPath: String
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "local.d0ne1s.polepole.dirwatcher")

    nonisolated(unsafe) private var stream: FSEventStreamRef?
    nonisolated(unsafe) private var debounce: DispatchWorkItem?
    nonisolated(unsafe) private var started = false
    nonisolated(unsafe) private var stopped = false

    init(
        root: URL,
        debounceInterval: TimeInterval = 0.5,
        onChange: @escaping @Sendable () -> Void
    ) {
        // FSEvents callback は常に「symlink を解決した正規 path」を返す
        // (`/tmp` → `/private/tmp` 等)。比較側もここで合わせておかないと
        // shouldIgnore / hasPrefix がずれて全 event が捨てられる。
        // `URL.resolvingSymlinksInPath()` も `NSString.resolvingSymlinksInPath` も
        // 互換性配慮で `/tmp` を解決しないため、`realpath(3)` を使う。
        let resolved: String
        if let cstr = realpath(root.path, nil) {
            resolved = String(cString: cstr)
            free(cstr)
        } else {
            resolved = root.path
        }
        self.root = URL(fileURLWithPath: resolved, isDirectory: true)
        self.rootPath = resolved
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        // 保険: 明示 stop() が呼ばれていなくても deinit で必ず止める。
        // 通常は FileIndex.deinit が watcher.stop() を呼ぶ経路で先に止まっている。
        stop()
    }

    /// FSEvents stream を起動する。`queue.sync` で同期的に完了してから return する。
    /// 「stream を張ってから initial rebuild」の順序が保てるように。
    func start() {
        queue.sync { [self] in
            guard !started, !stopped else { return }
            started = true

            // context.retain で FSEvents 側に strong ref を取らせる。
            // in-flight callback が解放済み self を `takeUnretainedValue` する race を防ぐ。
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: fsEventsRetain,
                release: fsEventsRelease,
                copyDescription: nil
            )
            // `kFSEventStreamCreateFlagIgnoreSelf` は意図的に外す:
            // - PolePole 自身は project ファイルを書き換えない (read-only) ので
            //   実害がない
            // - 逆に AUTO_FSEVENTS_PROBE のような自プロセスからの touch/rm が
            //   イベントとして検知できなくなり VERIFY ができなくなる
            let flags: UInt32 = UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes
            )
            guard let s = FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventsCallback,
                &context,
                [rootPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                flags
            ) else {
                Logger.shared.warn("[fsevents] FSEventStreamCreate failed for \(rootPath)")
                return
            }
            FSEventStreamSetDispatchQueue(s, queue)
            // FSEventStreamStart は dispatch queue scheduling の問題 (queue が無効等)
            // で false を返すことがある。握りつぶすと「ログ上は started、実態は監視
            // されていない」状態になるので、失敗時は invalidate + release してロール
            // バックする。
            guard FSEventStreamStart(s) else {
                Logger.shared.warn("[fsevents] FSEventStreamStart failed for \(rootPath)")
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                started = false
                return
            }
            stream = s
            Logger.shared.debug("[fsevents] start root=\(rootPath)")
        }
    }

    /// stream を停止する。`queue.sync` で in-flight callback を drain してから
    /// `FSEventStreamStop` / `Invalidate` / `Release` を呼ぶ。Release が context.release
    /// を発火させて FSEvents 側の strong ref が落ちる。
    /// idempotent: 複数回呼んでも安全。
    ///
    /// **呼び出し制約**: `queue` (= `dirwatcher` の serial queue) の中から呼ぶと
    /// `queue.sync` で self deadlock する。今のところ call site は FileIndex.deinit
    /// と DirectoryChangeWatcher.deinit のみで、どちらも queue 外なので問題ない。
    /// 将来 callback 内部から `stop()` を呼びたくなったら DispatchSpecificKey で
    /// 再入判定する。
    func stop() {
        queue.sync { [self] in
            guard !stopped else { return }
            stopped = true
            if let s = stream {
                FSEventStreamStop(s)
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
            }
            stream = nil
            debounce?.cancel()
            debounce = nil
        }
    }

    /// FSEvents callback から呼ばれる。queue 上で実行される前提。
    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        var anyRelevant = false
        for i in 0..<paths.count {
            let f = i < flags.count ? flags[i] : 0
            // 取りこぼし系は path 判定をスキップして即発火
            let mustRescan = (f & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0
                || (f & UInt32(kFSEventStreamEventFlagUserDropped)) != 0
                || (f & UInt32(kFSEventStreamEventFlagKernelDropped)) != 0
                || (f & UInt32(kFSEventStreamEventFlagRootChanged)) != 0
            if mustRescan {
                anyRelevant = true
                break
            }
            if !shouldIgnore(path: paths[i]) {
                anyRelevant = true
            }
        }
        guard anyRelevant else { return }

        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onChange()
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    /// path を root からの相対 path components に分解し、各 component を `.git`
    /// および `.DS_Store` と突き合わせる。
    /// 文字列 contains だと `.github` を `.git` と誤判定するので component 単位で見る。
    ///
    /// `IgnoredDirectories` (node_modules / .build 等) は **filter しない**:
    /// gitignore に従って scanViaGit が entries から除外するので、rebuild が走っても
    /// 結果は変わらない。watcher と scan の対象がずれることのほうがバグの温床。
    /// storm 抑制は debounce + minRebuildInterval (FileIndex 側) で行う。
    private func shouldIgnore(path: String) -> Bool {
        guard path.hasPrefix(rootPath) else { return true } // root 外は無視
        let rel = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !rel.isEmpty else { return false }
        let components = rel.split(separator: "/").map(String.init)
        for comp in components {
            if comp == ".git" { return true }
            if comp == ".DS_Store" { return true }
        }
        return false
    }
}

// MARK: - C callbacks

/// FSEventStreamContext.retain: FSEvents が info ポインタを保持するときに呼ばれる。
/// Unmanaged.retain で refcount を +1 して、FSEvents が strong ref を握る形にする。
private func fsEventsRetain(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let info else { return nil }
    let _ = Unmanaged<DirectoryChangeWatcher>.fromOpaque(info).retain()
    return info
}

/// FSEventStreamContext.release: FSEventStreamRelease 時に呼ばれる。strong ref を解放。
private func fsEventsRelease(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<DirectoryChangeWatcher>.fromOpaque(info).release()
}

/// FSEvents は C function pointer を要求するので、トップレベル関数 (no capture) で受ける。
/// `clientInfo` から `Unmanaged.fromOpaque` で watcher を復元する。
/// context.retain で FSEvents が strong ref を握っているので、ここで触る self は
/// 必ず生きている (`stop()` で stream release されるまで)。
private func fsEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientInfo else { return }
    let watcher = Unmanaged<DirectoryChangeWatcher>.fromOpaque(clientInfo).takeUnretainedValue()

    // kFSEventStreamCreateFlagUseCFTypes を付けているので eventPaths は CFArray<CFString>。
    // unsafeBitCast で CFArray を取り出し、`as! [String]` で bridge する。
    let cfArrayPtr = Unmanaged<CFArray>.fromOpaque(eventPaths)
    let paths: [String] = (cfArrayPtr.takeUnretainedValue() as? [String]) ?? []

    var flags: [FSEventStreamEventFlags] = []
    flags.reserveCapacity(numEvents)
    for i in 0..<numEvents {
        flags.append(eventFlags[i])
    }
    watcher.handleEvents(paths: paths, flags: flags)
}
