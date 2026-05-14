import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// プロジェクト一覧サイドバー。
///
/// - 中央: ピン留めセクション + 一時セクション（cmux 風）
/// - 下部: 「+」ボタン → NSOpenPanel でフォルダ追加（一時プロジェクトの末尾に追加）
/// - 行右クリック: ピン留め切替・閉じる・編集
/// - ドラッグ&ドロップで並び替え可能（pinned/temporary 横断で auto pin/unpin）
struct LeftSidebarView: View {
    @ObservedObject var projects: ProjectsModel = .shared
    @State private var editingProject: Project?
    /// drop hover 中の対象。`.before(id)` か `.after(id)`、または `.endOf(...)`。
    @State private var dropIndicator: DropIndicator?

    /// 行内での drop 位置の視覚化用。
    enum DropIndicator: Equatable {
        case beforeRow(UUID)
        case afterRow(UUID)
        case endOfPinned
        case endOfTemporary
    }

    private static let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            footer
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

    private var footer: some View {
        HStack {
            Button(action: addProject) {
                Image(systemName: "plus")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add Folder")
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
                Text("Add a project")
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
                        // pinned セクション末尾の drop zone（divider と兼用、太め目）
                        sectionEndDropZone(.endOfPinned)
                        Divider().padding(.vertical, 2)
                    } else {
                        // pinned が空でもピン留めセクションへ drop できるよう薄い zone を置く
                        emptyPinnedDropZone
                    }
                    ForEach(projects.temporary) { project in
                        row(project)
                    }
                    sectionEndDropZone(.endOfTemporary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// 未読プロジェクトの強調色（紫系）。左端バーと薄いティント背景に使う。
    private static let unreadAccent = Color(red: 0.58, green: 0.40, blue: 0.92)

    /// 行の背景色。アクティブが最優先、次に未読（紫のごく薄いティント）。
    private func rowBackground(isActive: Bool, hasUnread: Bool) -> Color {
        if isActive { return Color.accentColor.opacity(0.25) }
        if hasUnread { return Self.unreadAccent.opacity(0.13) }
        return Color.clear
    }

    private func row(_ project: Project) -> some View {
        let isActive = projects.activeProject?.id == project.id
        let missing = project.isMissing
        let hasUnread = projects.unreadProjectIDs.contains(project.id)
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
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .background(rowBackground(isActive: isActive, hasUnread: hasUnread))
        .opacity(missing ? 0.55 : 1.0)
        .overlay(alignment: .top) {
            if dropIndicator == .beforeRow(project.id) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if dropIndicator == .afterRow(project.id) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .leading) {
            // 未読プロジェクトは左端に紫の縦バー（focused タブ表示と同じ手法）
            if hasUnread {
                Self.unreadAccent.frame(width: 3)
            }
        }
        .help(missing ? "Path not found: \(project.path.path)" : project.path.path)
        .contentShape(Rectangle())
        .onTapGesture {
            // missing なプロジェクトは setActive 側で弾かれ、toast が出る（要件 2: クリックしても開けない）。
            projects.setActive(project)
        }
        .contextMenu {
            Button(project.isPinned ? "Unpin" : "Pin") {
                projects.togglePin(project)
            }
            Button("Edit…") {
                editingProject = project
            }
            if missing {
                Button("Relocate…") {
                    relocateProject(project)
                }
            }
            Button("Close") {
                projects.close(project)
            }
        }
        .draggable(project.id.uuidString) {
            // ドラッグ中のプレビュー
            HStack(spacing: 6) {
                ProjectAvatarView(
                    name: project.displayName,
                    colorKey: project.colorKey,
                    isMissing: missing,
                    size: 16
                )
                Text(project.displayName)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(4)
        }
        .dropDestination(for: String.self) { items, location in
            handleRowDrop(items: items, target: project, location: location)
        } isTargeted: { isTargeted in
            if !isTargeted, case let .beforeRow(id) = dropIndicator, id == project.id {
                dropIndicator = nil
            } else if !isTargeted, case let .afterRow(id) = dropIndicator, id == project.id {
                dropIndicator = nil
            } else if isTargeted {
                // 行に入った瞬間は before として仮表示。確定時に location で再判定する。
                dropIndicator = .beforeRow(project.id)
            }
        }
    }

    @ViewBuilder
    private var emptyPinnedDropZone: some View {
        sectionEndDropZone(.endOfPinned)
            .frame(height: 16)
    }

    @ViewBuilder
    private func sectionEndDropZone(_ kind: DropIndicator) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if dropIndicator == kind {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let sourceID = parseSourceID(items) else { return false }
                let target: ProjectsModel.DropPosition = (kind == .endOfPinned) ? .endOfPinned : .endOfTemporary
                projects.move(sourceID, to: target)
                dropIndicator = nil
                return true
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropIndicator = kind
                } else if dropIndicator == kind {
                    dropIndicator = nil
                }
            }
    }

    private func handleRowDrop(items: [String], target: Project, location: CGPoint) -> Bool {
        guard let sourceID = parseSourceID(items) else { return false }
        // location は行ローカル座標。上半分 → before、下半分 → after。
        let isAfter = location.y > Self.rowHeight / 2
        let position: ProjectsModel.DropPosition = isAfter
            ? .afterProject(target.id)
            : .beforeProject(target.id)
        projects.move(sourceID, to: position)
        dropIndicator = nil
        return true
    }

    private func parseSourceID(_ items: [String]) -> UUID? {
        guard let first = items.first else { return nil }
        return UUID(uuidString: first)
    }

    // MARK: - 「+」ボタンの動作

    private func addProject() {
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

    private func relocateProject(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Relocate folder for \"\(project.displayName)\""
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            projects.relocate(project, to: url)
        }
    }
}
