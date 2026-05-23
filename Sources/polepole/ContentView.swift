import SwiftUI

struct ContentView: View {
    @ObservedObject private var licenseStore = LicenseStore.shared

    var body: some View {
        ZStack {
            RootLayoutView()
            // ライセンスが locked (= トライアル期限切れ or deactivated) のときは PaywallView を
            // 最前面に重ねて、背景の機能を全停止する。
            // 要件 6 / 8.3 に従い、メニュー操作・キーボード入力は SwiftUI の overlay が
            // first responder を奪うので background view には届かない。
            if licenseStore.state.isLocked {
                PaywallView()
                    .transition(.opacity)
            }
        }
        .onAppear {
            // 起動直後に画面が出てから即時 refresh する (init で 1 度走っているが、
            // POLEPOLE_TEST_LICENSE_FAKE_NOW で時計を変えた検証時にも反映させるため)。
            licenseStore.refreshFromDisk()
            // 週1 verify の発火 (issued_at から 7 日経過していれば走る)。
            // 通信が要るので背景タスクで投げる。失敗してもグレース 30 日に守られる。
            Task { await licenseStore.verifyIfNeeded() }
        }
    }
}

#Preview {
    ContentView()
}
