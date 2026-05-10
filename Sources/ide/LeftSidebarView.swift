import SwiftUI
import AppKit

/// プロジェクト一覧サイドバー。
///
/// - 上部: 「+」ボタン → NSOpenPanel でフォルダ追加（一時プロジェクト）
/// - 中央: ピン留めセクション + 一時セクション（cmux 風）
/// - 行右クリック: ピン留め切替・閉じる
///
/// 永続化と missing 表示は step3、ドラッグ並び替えは step3 以降。
struct LeftSidebarView: View {
    @ObservedObject var projects: ProjectsModel = .shared
    @State private var editingProject: Project?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
        .sheet(item: $editingProject) { project in
            ProjectEditSheet(
                project: project,
                onSave: { name, colorKey in
                    projects.update(project, displayName: name, colorKey: colorKey)
                    editingProject = nil
                },
                onCancel: { editingProject = nil }
            )
        }
    }

    private var header: some View {
        HStack {
            Button(action: addProject) {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("フォルダを追加")
            .accessibilityIdentifier("AddProjectButton")
            .frame(height: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var list: some View {
        if projects.allOrdered.isEmpty {
            VStack {
                Spacer()
                Text("プロジェクトを追加")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !projects.pinned.isEmpty {
                        ForEach(projects.pinned) { project in
                            row(project)
                        }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(projects.temporary) { project in
                        row(project)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ project: Project) -> some View {
        let isActive = projects.activeProject?.id == project.id
        let missing = project.isMissing
        return HStack(spacing: 8) {
            ProjectAvatarView(
                name: project.displayName,
                colorKey: project.colorKey,
                isMissing: missing,
                size: 18
            )
            Text(project.displayName)
                .font(.system(size: 12, weight: project.isPinned ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
        .opacity(missing ? 0.55 : 1.0)
        .help(missing ? "パスが見つかりません: \(project.path.path)" : project.path.path)
        .contentShape(Rectangle())
        .onTapGesture {
            // missing でもアクティブにはできる（中央ペインで状態を見てもらう）
            projects.setActive(project)
        }
        .contextMenu {
            Button(project.isPinned ? "ピン解除" : "ピン留め") {
                projects.togglePin(project)
            }
            Button("編集…") {
                editingProject = project
            }
            if missing {
                Button("再選択…") {
                    relocateProject(project)
                }
            }
            Button("閉じる") {
                projects.close(project)
            }
        }
    }

    // MARK: - 「+」ボタンの動作

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "プロジェクトのフォルダを選択"
        panel.prompt = "追加"
        if panel.runModal() == .OK, let url = panel.url {
            projects.addTemporary(path: url)
        }
    }

    private func relocateProject(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "「\(project.displayName)」のフォルダを再選択"
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url {
            projects.relocate(project, to: url)
        }
    }
}
