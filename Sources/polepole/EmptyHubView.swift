import SwiftUI
import AppKit

/// プロジェクトが 0 件のときの中央ペイン統一ハブ。
///
/// - 上部: PolePole ロゴ + Get started
/// - 中段: Choose a folder... プライマリボタン
/// - 区切り: ── or ──
/// - Import projects... ボタン（バックグラウンド scan の進捗を反映、押下で ImportSheet 表示）
/// - 下部: How to use PolePole リンク（外部ブラウザで polepole.dev/guide を開く）
///
/// `EmptyHubView` の表示と同時に `scanner.scanIfNeeded()` を発火する。
/// 1 件以上プロジェクトがある状態ではそもそも CenterPaneView が EmptyHubView を出さないので、
/// 「常時の起動コストは 0、空状態のときだけ scan」を維持する。
struct EmptyHubView: View {
    @ObservedObject var projects: ProjectsModel = .shared
    @StateObject private var scanner = ImportScanner()
    @State private var showImportSheet = false

    private static let guideURL = URL(string: "https://polepole.dev/guide")!

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 24) {
                header
                VStack(spacing: 16) {
                    chooseFolderButton
                    orSeparator
                    importButton
                }
                .frame(maxWidth: 380)
                guideLink
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await scanner.scanIfNeeded() }
        .sheet(isPresented: $showImportSheet) {
            ImportSheetView(scanner: scanner, onClose: { showImportSheet = false })
                .frame(minWidth: 640, minHeight: 480)
        }
    }

    // MARK: - subviews

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Get started with PolePole")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Add a project folder, or import from tools you already use.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var chooseFolderButton: some View {
        Button(action: chooseFolder) {
            Label("Choose a folder…", systemImage: "folder.badge.plus")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }

    private var orSeparator: some View {
        HStack {
            VStack { Divider() }
            Text("or")
                .font(.caption)
                .foregroundStyle(.tertiary)
            VStack { Divider() }
        }
    }

    @ViewBuilder
    private var importButton: some View {
        let count = scanner.result?.candidates.count ?? 0
        let isLoading = scanner.isScanning
        let hasResult = scanner.result != nil
        let enabled = hasResult && count > 0

        VStack(spacing: 6) {
            Button(action: { showImportSheet = true }) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if enabled {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    Text(buttonTitle(count: count, isLoading: isLoading, hasResult: hasResult))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .disabled(!enabled)

            if let r = scanner.result, !r.candidates.isEmpty {
                Text(sourcesSummary(r.candidates))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if !isLoading, hasResult {
                Text("No projects detected from cmux, tmuxinator, or VS Code.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func buttonTitle(count: Int, isLoading: Bool, hasResult: Bool) -> String {
        if isLoading { return "Looking for projects to import…" }
        if !hasResult { return "Import projects…" }
        if count == 0 { return "No projects to import" }
        return "Import projects (\(count))"
    }

    private func sourcesSummary(_ candidates: [ImportCandidate]) -> String {
        let counts = Dictionary(grouping: candidates.flatMap(\.sources), by: { $0 }).mapValues(\.count)
        let order = ["cmux", "ghq", "tmuxinator", "vscode", "cursor"]
        let parts = order.compactMap { id -> String? in
            guard let c = counts[id], c > 0 else { return nil }
            return "\(displayLabel(for: id)) \(c)"
        }
        return parts.joined(separator: " · ")
    }

    private func displayLabel(for sourceId: String) -> String {
        switch sourceId {
        case "ghq": return "local"
        case "vscode": return "VS Code"
        case "cursor": return "Cursor"
        default: return sourceId
        }
    }

    private var guideLink: some View {
        Button(action: { NSWorkspace.shared.open(Self.guideURL) }) {
            HStack(spacing: 6) {
                Image(systemName: "book")
                Text("How to use PolePole")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(Self.guideURL.absoluteString)
    }

    // MARK: - actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder"
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            projects.addTemporary(path: url)
        }
    }
}
