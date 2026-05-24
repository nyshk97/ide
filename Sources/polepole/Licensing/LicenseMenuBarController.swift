import AppKit
import Combine
import SwiftUI

/// トライアル残日数 7 日以下のときに menu bar (右上のステータスバー) に
/// 警告アイコンを表示する controller。
///
/// 要件: 「静かなリマインド」。
/// - 残日数 8 日以上 or アクティベート済み: アイコン非表示
/// - 残日数 7 日以下 (trial): アイコン表示
/// - 残日数 0 or deactivated: PaywallView が前面に出ているのでこちらは出さない
///   (PaywallView の重複案内になるため)
///
/// クリックするとプルダウンメニューが開いて、
/// 「PolePole を購入...」「ライセンス設定を開く...」が選べる。
@MainActor
final class LicenseMenuBarController {
    static let shared = LicenseMenuBarController()

    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?

    private init() {}

    /// アプリ起動時に 1 回呼ぶ。`LicenseStore.shared.state` の変化を購読して
    /// 表示状態を更新する。
    func start() {
        // 初期表示
        update(for: LicenseStore.shared.state)
        cancellable = LicenseStore.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.update(for: state)
            }
    }

    private func update(for state: LicenseState) {
        let daysLeft: Int? = {
            if case .trial(let d) = state, d <= 7 { return d }
            return nil
        }()
        if let days = daysLeft {
            show(daysLeft: days)
        } else {
            hide()
        }
    }

    private func show(daysLeft: Int) {
        let item: NSStatusItem
        if let existing = statusItem {
            item = existing
        } else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
        }
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "PolePole トライアル残り \(daysLeft) 日"
            )
            // SF Symbol はテンプレートにするとアイコン側で着色できる。
            // この警告だけは目立たせたいので明示的にオレンジで描く。
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            button.image = image?.withSymbolConfiguration(cfg)
            button.toolTip = "PolePole トライアル残り \(daysLeft) 日"
            // 「アイコンの後ろに日数を出すか」は迷うが、Apple のメニューバー慣行
            // (アイコン単体 / 必要時だけ数字) に倣って「3日以下のとき数字を併記」する。
            if daysLeft <= 3 {
                button.title = " \(daysLeft)"
            } else {
                button.title = ""
            }
        }
        item.menu = buildMenu()
    }

    private func hide() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let purchase = NSMenuItem(
            title: "PolePole を購入...",
            action: #selector(openPurchase),
            keyEquivalent: ""
        )
        purchase.target = self
        menu.addItem(purchase)

        let settings = NSMenuItem(
            title: "ライセンス設定を開く...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        menu.addItem(settings)
        return menu
    }

    @objc private func openPurchase() {
        if let url = URL(string: "https://polepole.dev/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        // macOS 14+ は showSettingsWindow:、macOS 13 以下は showPreferencesWindow: で
        // SwiftUI Settings シーンが開く。どちらも非公開 selector 扱いだが SwiftUI が
        // 内部で投げているもの。両方試して通った方を採用する。
        if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
