import SwiftUI

/// 候補リスト UI（EmptyHubView の sheet と Settings の Import タブから共有して使う共通 View）。
///
/// - ヘッダ: `Found N unique projects · M already in PolePole`
/// - source フィルタ chips（排他 toggle、`All` がデフォルト）
/// - リスト: 1 行 = 1 候補（チェックボックス + pin + displayName + path + source バッジ + lastAccess）
/// - 折りたたみ `Already in PolePole (M hidden)`
/// - クイック選択 `All` / `None` / `cmux pinned only`
/// - `Import N selected` → `ProjectsModel.importProjects(_:)` 経由
struct ImportSheetView: View {
    @ObservedObject var scanner: ImportScanner
    /// nil の場合は close ボタンを出さない（Settings の Import タブ embed 時）。
    let onClose: (() -> Void)?

    @State private var selected: Set<String> = []  // canonical key
    @State private var sourceFilter: SourceFilter = .all
    @State private var showAlreadyImported = false

    enum SourceFilter: Hashable {
        case all
        case source(String)

        var key: String {
            if case let .source(id) = self { return id }
            return "all"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: initializeDefaultSelection)
        .onChange(of: scanner.result?.candidates.map(\.canonicalKey) ?? []) { _, _ in
            initializeDefaultSelection()
        }
    }

    private var allCandidates: [ImportCandidate] {
        scanner.result?.candidates ?? []
    }

    private var alreadyImported: [ImportCandidate] {
        scanner.result?.alreadyImported ?? []
    }

    private var filteredCandidates: [ImportCandidate] {
        switch sourceFilter {
        case .all:
            return allCandidates
        case .source(let id):
            return allCandidates.filter { $0.sources.contains(id) }
        }
    }

    private var sourceChipsItems: [(SourceFilter, String, Int)] {
        // counts per source (only over candidates, not alreadyImported)
        var counts: [String: Int] = [:]
        for c in allCandidates {
            for s in c.sources { counts[s, default: 0] += 1 }
        }
        var items: [(SourceFilter, String, Int)] = [(.all, "All", allCandidates.count)]
        let order = ["cmux", "ghq", "tmuxinator", "vscode", "cursor"]
        for id in order {
            if let n = counts[id], n > 0 {
                items.append((.source(id), displayLabel(for: id), n))
            }
        }
        return items
    }

    private func displayLabel(for sourceId: String) -> String {
        switch sourceId {
        case "cmux": return "cmux"
        case "ghq": return "local"
        case "tmuxinator": return "tmuxinator"
        case "vscode": return "VS Code"
        case "cursor": return "Cursor"
        default: return sourceId
        }
    }

    // MARK: - sections

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Import projects")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if scanner.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(headerSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            chipBar
        }
        .padding(16)
    }

    private var headerSubtitle: String {
        let n = allCandidates.count
        let m = alreadyImported.count
        if scanner.isScanning && scanner.result == nil { return "Looking for projects from cmux, tmuxinator, ghq, and VS Code…" }
        if n == 0 && m == 0 { return "No projects detected." }
        if m == 0 { return "Found \(n) unique projects." }
        return "Found \(n) unique projects · \(m) already in PolePole"
    }

    private var chipBar: some View {
        HStack(spacing: 8) {
            ForEach(sourceChipsItems, id: \.0.key) { item in
                let (filter, label, count) = item
                let isSelected = filter == sourceFilter
                Button(action: { sourceFilter = filter }) {
                    HStack(spacing: 4) {
                        Text(label)
                        Text("\(count)")
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.2))
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if allCandidates.isEmpty && alreadyImported.isEmpty {
            VStack {
                Spacer()
                Text(scanner.isScanning ? "Scanning…" : "Nothing to import.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredCandidates, id: \.canonicalKey) { c in
                        candidateRow(c)
                        Divider().padding(.leading, 36)
                    }
                    if !alreadyImported.isEmpty {
                        alreadyImportedSection
                    }
                }
            }
        }
    }

    private func candidateRow(_ c: ImportCandidate) -> some View {
        let isOn = Binding(
            get: { selected.contains(c.canonicalKey) },
            set: { newValue in
                if newValue { selected.insert(c.canonicalKey) }
                else { selected.remove(c.canonicalKey) }
            }
        )
        let displayName = c.displayName ?? (c.preferredPath as NSString).lastPathComponent

        return HStack(spacing: 10) {
            Toggle("", isOn: isOn).labelsHidden()
            if c.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.body)
                Text(displayPath(c.preferredPath))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            sourceBadges(c.sources)
            if let lastAccess = c.lastAccessAt, isVSCodeOnly(c), let age = ageLabel(for: lastAccess) {
                Text(age)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    private func isVSCodeOnly(_ c: ImportCandidate) -> Bool {
        let set = Set(c.sources)
        return set.isSubset(of: ["vscode", "cursor"])
    }

    private func ageLabel(for date: Date) -> String? {
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days < 30 { return nil }
        return "last opened \(days)d ago"
    }

    private func sourceBadges(_ sources: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(sources, id: \.self) { id in
                Text(displayLabel(for: id))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badgeColor(for: id).opacity(0.18)))
                    .foregroundStyle(badgeColor(for: id))
            }
        }
    }

    private func badgeColor(for sourceId: String) -> Color {
        switch sourceId {
        case "cmux": return .purple
        case "ghq": return .green
        case "tmuxinator": return .orange
        case "vscode": return .blue
        case "cursor": return .indigo
        default: return .secondary
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    @ViewBuilder
    private var alreadyImportedSection: some View {
        DisclosureGroup(isExpanded: $showAlreadyImported) {
            VStack(spacing: 0) {
                ForEach(alreadyImported, id: \.canonicalKey) { c in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayName ?? (c.preferredPath as NSString).lastPathComponent)
                                .font(.body)
                            Text(displayPath(c.preferredPath))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        sourceBadges(c.sources)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .opacity(0.7)
                    Divider().padding(.leading, 36)
                }
            }
        } label: {
            Text("Already in PolePole (\(alreadyImported.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Button("All") { selected = Set(allCandidates.map(\.canonicalKey)) }
                .buttonStyle(.bordered)
            Button("None") { selected.removeAll() }
                .buttonStyle(.bordered)
            Spacer()
            if let onClose {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            Button(action: performImport) {
                Text(selected.isEmpty ? "Import" : "Import \(selected.count) selected")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - actions

    private func initializeDefaultSelection() {
        guard let candidates = scanner.result?.candidates, !candidates.isEmpty else { return }
        // 既に初期化済み（手動編集の結果かもしれない）なら触らない
        if !selected.isEmpty { return }
        selected = Set(candidates.filter(\.defaultSelected).map(\.canonicalKey))
    }

    private func performImport() {
        let chosen = allCandidates.filter { selected.contains($0.canonicalKey) }
        let payloads = chosen.map {
            ImportPayload(
                preferredPath: $0.preferredPath,
                displayName: $0.displayName,
                isPinned: $0.isPinned
            )
        }
        let added = ProjectsModel.shared.importProjects(payloads)
        ErrorBus.shared.notify("Imported \(added.count) project\(added.count == 1 ? "" : "s")", kind: .info)
        selected.removeAll()
        if let onClose {
            onClose()
        } else {
            // Settings 埋め込み時は閉じずに、scan を回し直して
            // 取り込み済みエントリを Already in PolePole 側へ移動する。
            Task { await scanner.scan() }
        }
    }
}
