import SwiftUI
import GhosttyKit

@main
struct IdeApp: App {
    init() {
        PocLog.reset()
        GhosttyManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(TerminalTabsModel.shared)
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
