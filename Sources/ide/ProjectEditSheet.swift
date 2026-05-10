import SwiftUI

/// プロジェクトの表示名と色を編集するモーダルシート。
///
/// 色は 10 色パレット + 「自動」（名前から決定論的に割り当て）から選択。
/// スウォッチには色サンプルが見えるようプレビュー円を並べる。
struct ProjectEditSheet: View {
    let project: Project
    let onSave: (_ displayName: String, _ colorKey: String?) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var colorKey: String?
    @FocusState private var nameFocused: Bool

    init(
        project: Project,
        onSave: @escaping (String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.project = project
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: project.displayName)
        _colorKey = State(initialValue: project.colorKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("プロジェクトを編集")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("名前").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(save)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("色").font(.caption).foregroundStyle(.secondary)
                colorSwatches
            }

            Text(project.path.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("完了", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private var colorSwatches: some View {
        HStack(spacing: 8) {
            autoSwatch
            ForEach(ProjectColor.allCases) { c in
                swatch(color: c.color, label: c.label, isSelected: colorKey == c.rawValue) {
                    colorKey = c.rawValue
                }
            }
        }
    }

    private var autoSwatch: some View {
        let auto = ProjectColor.automatic(for: name)
        return Button {
            colorKey = nil
        } label: {
            ZStack {
                Circle()
                    .fill(auto.color.opacity(0.4))
                Circle()
                    .strokeBorder(
                        Color.secondary,
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
                Text("A")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(width: 24, height: 24)
            .overlay(
                Circle()
                    .stroke(Color.accentColor, lineWidth: colorKey == nil ? 2 : 0)
                    .padding(-3)
            )
        }
        .buttonStyle(.plain)
        .help("自動 (名前から決定)")
    }

    private func swatch(color: Color, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func save() {
        onSave(name, colorKey)
    }
}
