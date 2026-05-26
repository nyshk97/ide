import SwiftUI

/// Settings ウィンドウの Import タブ。
/// EmptyHubView と違い、プロジェクトが既に登録されているユーザーが「あとから」インポートする経路。
/// 既存プロジェクトは alreadyImported 折りたたみに表示される。
struct ImportSettingsView: View {
    @StateObject private var scanner = ImportScanner()

    var body: some View {
        VStack(spacing: 0) {
            ImportSheetView(scanner: scanner, onClose: nil)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .task { await scanner.scanIfNeeded() }
    }
}
