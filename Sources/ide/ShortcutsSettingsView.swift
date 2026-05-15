import AppKit
import SwiftUI

/// Cmd+, で開かれる Settings シーンの中身。
/// ShortcutsStore の 3 つのバインドを編集する。
struct ShortcutsSettingsView: View {
    @ObservedObject private var store = ShortcutsStore.shared
    @State private var recording: ShortcutAction?
    @State private var recordingMonitor: Any?
    @State private var recordingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard Shortcuts")
                .font(.title2).bold()

            Text("Click Edit and press a key combination. A modifier (⌘ / ⌃ / ⌥) is required.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    row(for: action)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Reset All to Defaults") {
                    stopRecording()
                    store.resetAll()
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private func row(for action: ShortcutAction) -> some View {
        let combo = store.combo(for: action)
        let isRecording = (recording == action)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(action.label)
                    .frame(width: 200, alignment: .leading)

                if isRecording {
                    Text("Press a key combo…")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Cancel") { stopRecording() }
                } else {
                    Text(combo.display)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.15))
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Edit") { startRecording(action) }
                    Button("Reset") { store.resetOne(action) }
                        .disabled(combo == ShortcutAction.defaults[action])
                }
            }

            if isRecording, let err = recordingError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 212)
            } else if !isRecording, let conflict = conflictMessage(for: action) {
                Text("⚠︎ \(conflict)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, 212)
            }
        }
    }

    private func conflictMessage(for action: ShortcutAction) -> String? {
        let combo = store.combo(for: action)
        for other in ShortcutAction.allCases where other != action {
            let oc = store.combo(for: other)
            if oc.keyCode == combo.keyCode && oc.modifierFlags == combo.modifierFlags {
                return "Conflicts with \(other.label)"
            }
        }
        if let fixed = FixedShortcuts.conflict(for: combo) {
            return "Conflicts with \(fixed)"
        }
        return nil
    }

    // MARK: - Recording

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        recordingError = nil
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleRecorded(event: event, for: action)
            return nil  // 録音中は全 keyDown を消費して他に流さない
        }
    }

    private func stopRecording() {
        if let m = recordingMonitor {
            NSEvent.removeMonitor(m)
        }
        recordingMonitor = nil
        recording = nil
        recordingError = nil
    }

    private func handleRecorded(event: NSEvent, for action: ShortcutAction) {
        // Esc で録音キャンセル
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let combo = KeyCombo.from(event: event)
        guard combo.hasPrimaryModifier else {
            recordingError = "Modifier required (⌘ / ⌃ / ⌥). Try again."
            return
        }
        store.setCombo(combo, for: action)
        stopRecording()
    }
}
