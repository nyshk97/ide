import SwiftUI
import AppKit

/// Cmd+P で表示するクイック検索オーバーレイ。
/// テキスト入力 + 結果リスト + ↑↓ 選択 + Enter で preview を開く。
struct QuickSearchView: View {
    @ObservedObject var index: FileIndex
    @Binding var query: String
    @Binding var selection: Int
    let onSelect: (FileIndex.Entry) -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        let results = index.search(query)

        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search by file name or path", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .font(.system(size: 14))
                    .onSubmit {
                        if results.indices.contains(selection) {
                            onSelect(results[selection])
                        }
                    }
                Button {
                    index.includeIgnored.toggle()
                } label: {
                    Image(systemName: index.includeIgnored
                          ? "circle.fill"
                          : "circle.lefthalf.filled")
                        .foregroundStyle(index.includeIgnored ? Color.accentColor : .secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(index.includeIgnored
                      ? "Exclude ignored files from results"
                      : "Include ignored files in results")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            if !results.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, entry in
                                row(entry: entry, isSelected: idx == selection)
                                    .onTapGesture {
                                        onSelect(entry)
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) { _, newValue in
                        // Ctrl+N / ↓ などで選択が画面外に出たらスクロール追従。
                        // scrollTo は ForEach の id (= entry.id = URL) を target にする。
                        // ここで .id(idx) を別途付けると ForEach の identity と二重になり
                        // LazyVStack の diffing が壊れる（古い row が表示される）。
                        guard results.indices.contains(newValue) else { return }
                        proxy.scrollTo(results[newValue].id, anchor: .center)
                    }
                }
            } else if !query.isEmpty {
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
            selection = 0
            // ターミナル(Ghostty NSView) が AppKit の first responder を握っているので
            // 一度リセットしてから SwiftUI の @FocusState を立てる。1 tick 遅延が必要。
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            // クエリが変わったら選択を先頭にリセット
            selection = 0
        }
    }

    private func row(entry: FileIndex.Entry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.url.lastPathComponent)
                    .lineLimit(1)
                Text(entry.relativePath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
