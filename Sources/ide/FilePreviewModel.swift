import Foundation
import SwiftUI

/// 中央ペインで現在開いているファイルプレビューの状態。
/// プロジェクトごとに 1 インスタンス（ProjectsModel が dictionary で保持）。
@MainActor
final class FilePreviewModel: ObservableObject {
    /// プレビュー中のファイル URL。nil ならツリー表示。
    @Published var currentURL: URL?

    /// 履歴ナビ用（step9）。とりあえず保持だけ、UI は次 step。
    @Published private(set) var history: [URL] = []
    @Published private(set) var historyIndex: Int = -1

    /// プレビュー対象を切替（履歴に push）。URL の == は表記揺れで一致しないことがあるので
    /// 重複判定は `FilePathKey` で行う。
    func open(_ url: URL) {
        let key = FilePathKey(url)
        if let currentURL, FilePathKey(currentURL) == key { return }
        // 履歴の途中まで進んでいた場合、それ以降を破棄してから push
        if historyIndex >= 0 && historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        // 同じパスを連続で開くのは重複させない
        if let last = history.last, FilePathKey(last) == key {
            // 直前と同じなら積まない
        } else {
            history.append(url)
        }
        historyIndex = history.count - 1
        currentURL = url
    }

    /// プレビューを閉じてツリーに戻る。履歴は保持。
    func close() {
        currentURL = nil
        if findBarVisible { hideFindBar() }
    }

    // MARK: - ファイル内検索 (Cmd+F)

    /// プレビュー内検索バーを表示しているか。
    @Published var findBarVisible = false
    /// 検索語。FilePreviewView の TextField とバインドする。
    @Published var findQuery = "" {
        didSet {
            guard findBarVisible, findQuery != oldValue else { return }
            scheduleFind()
        }
    }
    /// マッチ総数。
    @Published private(set) var findMatchCount = 0
    /// 現在のマッチ位置（1-based、マッチなしは 0）。
    @Published private(set) var findMatchIndex = 0
    /// Cmd+F が押されるたびに増える。FilePreviewView が監視して TextField へ再フォーカスする。
    @Published private(set) var findFocusTick = 0

    private var findDebounceTask: Task<Void, Never>?

    /// Cmd+F: 検索バーを表示（既に表示中なら TextField へ再フォーカスし、検索語があれば再ハイライト）。
    func showFindBar() {
        findBarVisible = true
        findFocusTick &+= 1
        if !findQuery.isEmpty { scheduleFind() }
    }

    /// Esc / ✕: 検索バーを閉じてハイライトを消す（プレビュー自体は閉じない）。
    func hideFindBar() {
        guard findBarVisible else { return }
        findBarVisible = false
        findDebounceTask?.cancel()
        findMatchCount = 0
        findMatchIndex = 0
        PreviewWebController.shared.clearFind()
    }

    /// 次（forward=true）/ 前のマッチへ移動する。
    func findNext(forward: Bool) {
        guard findBarVisible, !findQuery.isEmpty else { return }
        Task { [weak self] in
            let r = await PreviewWebController.shared.findNext(forward: forward)
            guard let self, self.findBarVisible else { return }
            self.findMatchCount = r.count
            self.findMatchIndex = r.index
        }
    }

    /// 別ファイルを描画した後など、検索バーが開いていればハイライトとマッチ数を同期する。
    func refreshFindAfterContentChange() {
        guard findBarVisible, !findQuery.isEmpty else { return }
        Task { [weak self] in
            let r = await PreviewWebController.shared.findState()
            guard let self, self.findBarVisible, !self.findQuery.isEmpty else { return }
            if r.count > 0 {
                self.findMatchCount = r.count
                self.findMatchIndex = r.index
            } else {
                // viewer.js 側が再適用していない（直前に検索していなかった等）→ 改めて検索する
                self.scheduleFind()
            }
        }
    }

    private func scheduleFind() {
        findDebounceTask?.cancel()
        let q = findQuery
        findDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            let r = await PreviewWebController.shared.find(q)
            if Task.isCancelled { return }
            guard let self, self.findBarVisible else { return }
            self.findMatchCount = r.count
            self.findMatchIndex = r.index
        }
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentURL = history[historyIndex]
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentURL = history[historyIndex]
    }

    /// プレビュー中なら閉じる。ツリー表示中で履歴があれば、最後に見たファイルを再表示。
    /// Cmd+J / トグルボタン両方が呼ぶ。
    func toggle() {
        if currentURL != nil {
            currentURL = nil
        } else if historyIndex >= 0 && historyIndex < history.count {
            currentURL = history[historyIndex]
        }
    }

    /// ツリー表示中で「最後に見たファイル」へ戻れるか。トグルボタンの enable 判定に使う。
    var canRestorePreview: Bool {
        currentURL == nil && historyIndex >= 0 && historyIndex < history.count
    }
}

/// プレビューするファイル種別の判定結果。
enum FilePreviewKind {
    case code(Data, encoding: String.Encoding)
    case markdown(String)
    case image
    case pdf
    case binary
    case tooLarge(bytes: Int64)
    case external  // 50MB 超 / バイナリ
    case error(String)
}

/// `URL` をプレビュー可能な種別に分類するヘルパ。
enum FilePreviewClassifier {
    /// 5MB を超えるとサイズ確認、50MB 超は外部誘導（要件 6.4）。
    static let warnSize: Int64 = 5 * 1024 * 1024
    static let externalSize: Int64 = 50 * 1024 * 1024

    /// - Parameter allowLarge: 「読み込む」確認を経た場合 `true`。サイズしきい値を無視して
    ///   実際の種別（画像 / PDF / テキスト）を返す。
    static func classify(_ url: URL, allowLarge: Bool = false) -> FilePreviewKind {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return .error("File not found")
        }

        // サイズチェックを拡張子判定より前に行う（巨大な画像/PDF が素通りしてメモリを食わないように）。
        if !allowLarge {
            let attr = try? fm.attributesOfItem(atPath: url.path)
            let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
            if size > externalSize { return .external }
            if size > warnSize { return .tooLarge(bytes: size) }
        }

        // 拡張子で先に分かるものは早めに振り分け
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tiff":
            return .image
        case "pdf":
            return .pdf
        default:
            break
        }

        // 中身を読んでバイナリ判定（NUL 含むかどうか）
        guard let data = try? Data(contentsOf: url) else {
            return .error("Failed to load")
        }
        let limit = min(data.count, 8192)
        let head = data.prefix(limit)
        if head.contains(0) { return .binary }

        // UTF-8 デコード可能なら text 系
        guard let text = String(data: data, encoding: .utf8) else {
            return .external  // UTF-8 失敗は外部誘導（要件通り）
        }

        if ext == "md" || ext == "markdown" {
            return .markdown(text)
        }
        return .code(data, encoding: .utf8)
    }
}
