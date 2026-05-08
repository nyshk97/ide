import SwiftUI

struct ContentView: View {
    var body: some View {
        TabsView()
    }
}

#Preview {
    ContentView()
        .environmentObject(TerminalTabsModel())
}
