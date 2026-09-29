import SwiftUI
import AppKit

/// Cmd+O で表示するプロジェクト検索オーバーレイ。
/// 入力欄 + 結果リスト（行の見た目は Ctrl+M の `MRUOverlayView` に揃える）。
/// ↑↓ / Ctrl+N・P / Enter / Esc は `MRUKeyMonitor` が捕捉する。
struct ProjectSearchView: View {
    @ObservedObject var model: ProjectsModel

    @FocusState private var fieldFocused: Bool

    private static let rowHeight: CGFloat = 50
    private static let listPadding: CGFloat = 6

    var body: some View {
        let results = model.projectSearchResults()

        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search projects by name or path", text: $model.projectSearchQuery)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    // ScrollView は maxHeight まで広がるので、候補が少ないとパネル下に空白が残る。
                    // 行の高さを固定して件数から高さを決める（GeometryReader で実測すると、高さ 0 の
                    // ScrollView が中身をレイアウトせず実測も 0 のままになる）。
                    ScrollView {
                        resultList(results)
                    }
                    .frame(height: min(CGFloat(results.count) * Self.rowHeight + Self.listPadding * 2, 360))
                    .onChange(of: model.projectSearchSelection) { _, newValue in
                        // 選択が画面外に出たらスクロール追従（id は ForEach の identity = project.id）。
                        guard results.indices.contains(newValue) else { return }
                        proxy.scrollTo(results[newValue].id, anchor: .center)
                    }
                }
            } else if !model.projectSearchQuery.isEmpty {
                Text("No matches").foregroundStyle(.secondary).padding()
            }
        }
        .frame(width: 480)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        .onAppear {
            // ターミナル(Ghostty NSView) が first responder を握っているので一度外してから
            // @FocusState を立てる（QuickSearchView と同じ。1 tick 遅延が必要）。
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
    }

    /// プロジェクト数は多くても数十件なので Lazy にしない。
    private func resultList(_ results: [Project]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { idx, project in
                row(project: project, isSelected: idx == model.projectSearchSelection)
                    .contentShape(Rectangle())
                    .onTapGesture { model.projectSearchSelect(project) }
            }
        }
        .padding(Self.listPadding)
    }

    private func row(project: Project, isSelected: Bool) -> some View {
        let missing = project.isMissing
        let isCurrent = project.id == model.activeProject?.id
        return HStack(spacing: 8) {
            ProjectAvatarView(
                name: project.displayName,
                colorKey: project.colorKey,
                isMissing: missing,
                size: 22
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.system(size: 13, weight: project.isPinned ? .semibold : .regular))
                    .lineLimit(1)
                Text(project.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Text("Current")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(missing ? 0.55 : 1.0)
    }
}

