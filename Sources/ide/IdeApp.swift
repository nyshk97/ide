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
                .frame(minWidth: 1000, minHeight: 500)
        }
    }
}
