import SwiftUI
import GhosttyKit

@main
struct IdeApp: App {
    init() {
        PocLog.reset()
        GhosttyManager.shared.start()
        MRUKeyMonitor.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1000, minHeight: 500)
        }
    }
}
