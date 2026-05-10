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

    /// プレビュー対象を切替（履歴に push）。
    func open(_ url: URL) {
        if currentURL == url { return }
        // 履歴の途中まで進んでいた場合、それ以降を破棄してから push
        if historyIndex >= 0 && historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)..<history.count)
        }
        // 同じパスを連続で開くのは重複させない
        if history.last != url {
            history.append(url)
        }
        historyIndex = history.count - 1
        currentURL = url
    }

    /// プレビューを閉じてツリーに戻る。履歴は保持。
    func close() {
        currentURL = nil
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

    static func classify(_ url: URL) -> FilePreviewKind {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return .error("ファイルが見つかりません")
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

        // サイズチェック
        let attr = try? fm.attributesOfItem(atPath: url.path)
        let size = (attr?[.size] as? NSNumber)?.int64Value ?? 0
        if size > externalSize { return .external }
        if size > warnSize { return .tooLarge(bytes: size) }

        // 中身を読んでバイナリ判定（NUL 含むかどうか）
        guard let data = try? Data(contentsOf: url) else {
            return .error("読み込みに失敗しました")
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
