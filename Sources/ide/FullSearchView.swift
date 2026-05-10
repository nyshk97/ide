import SwiftUI
import AppKit

/// Cmd+Shift+F で表示する全文検索オーバーレイ。
struct FullSearchView: View {
    @Binding var query: String
    @Binding var hits: [SearchHit]
    @Binding var selection: Int
    @Binding var isSearching: Bool
    let onSubmit: () -> Void
    let onSelect: (SearchHit) -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("プロジェクト全体を grep（Enter で実行）", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .font(.system(size: 14))
                    .onSubmit { onSubmit() }
                if isSearching {
                    ProgressView().scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            if !hits.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.element.id) { idx, hit in
                            row(hit: hit, isSelected: idx == selection)
                                .onTapGesture { onSelect(hit) }
                        }
                    }
                }
                .frame(maxHeight: 380)
                Divider()
                Text("\(hits.count) 件" + (hits.count >= FullTextSearcher.resultLimit ? "（上限到達）" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else if !query.isEmpty && !isSearching {
                Text("該当なし").foregroundStyle(.secondary).padding()
            }
        }
        .frame(width: 560)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        .onAppear {
            // ターミナル(Ghostty NSView) が AppKit の first responder を握っているので
            // 一度リセットしてから SwiftUI の @FocusState を立てる。1 tick 遅延が必要。
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async {
                fieldFocused = true
            }
        }
    }

    private func row(hit: SearchHit, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(hit.url.lastPathComponent)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .semibold))
                Text(":\(hit.lineNumber)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(hit.lineText.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.30) : Color.clear)
    }
}
