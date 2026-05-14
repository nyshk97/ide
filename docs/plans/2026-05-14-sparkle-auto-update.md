# Sparkle 導入による「Check for Updates…」メニュー実装

## 概要・やりたいこと

IDE.app に Sparkle 2 を組み込み、メニューから「Check for Updates…」で自前アップデートを走らせられるようにする。

背景:

- 現状の配布は brew cask (`nyshk97/homebrew-tap`) 1 系統のみ。brew を使わないユーザーには届かない
- 将来的に有償化したい。brew tap の公開チャネルとは別に、自前で zip を配って課金 / ライセンス検証導線を握りたい
- リポジトリを private にしても更新が機能する構成にしておくと、有償化への移行がスムーズ

Sparkle 採用の利点:

- macOS で標準的な UX (`Check for Updates…` / 自動更新トースト) が手に入る
- EdDSA 署名で中間者改ざんを防げる
- Developer ID + notarize 済みなので Gatekeeper も通る
- 将来「無料 trial → アクティベーション」「ライセンス再検証」を組み合わせやすい

## 前提・わかっていること

### 決まったこと

- アップデートフレームワーク: **Sparkle 2** (SwiftPM 経由)
- メニュー項目ラベル: **"Check for Updates…"** (macOS 慣例)
- 更新チェック: **メニューからの手動実行のみ**。起動時自動チェックや定期チェックは入れない
- Debug ビルド (IDE Dev) でもメニュー項目は出す。Info.plist の `SUFeedURL` を Release 専用にして、Debug ではフィード URL を未設定にする → 押すと Sparkle のエラーダイアログが出る (`#if DEBUG` でコード分岐しない)
- 鍵管理: Sparkle の **EdDSA**。秘密鍵は keychain、公開鍵は `Info.plist` の `SUPublicEDKey` に Base64 で埋め込み
- brew cask 配布は当面継続。Sparkle は並走させる

### 未決事項 (Phase 2 前の人間判断ポイント)

appcast.xml / zip のホスト先 (private リポでも動くこと必須):

| 案 | 概要 | メリット | デメリット |
|---|---|---|---|
| A | 公開用の別 GitHub repo (`nyshk97/ide-releases`) を新設し public にする。本体 `nyshk97/ide` は将来 private 化可能 | 既存 `gh release` ワークフロー流用可。コスト 0 円 | release.sh が両 repo を扱う必要あり |
| B | Cloudflare R2 + 独自サブドメイン (`updates.<your-domain>/ide/`) | 商用化前提の構成。配信が高速。ドメイン自由 | ドメイン取得 + R2 設定の初期工数。月数 GB は無料 |
| C | 当面 `nyshk97/ide` (public) の Release Asset を使い続け、private 化時に移行 | 最小工数。今すぐ動く | private 化したタイミングで appcast/zip が 404 になる。SUFeedURL を変えるとユーザーの手元の Sparkle が古い URL を叩き続ける問題が出る |

### 既存コードの該当箇所

- `Sources/ide/IdeApp.swift:22` の `.commands` ブロックに「Check for Updates…」を追加
- `project.yml` に `packages:` セクション (未存在なので新設) と `targets.ide.dependencies` に Sparkle 追加
- `Resources/Info.plist` に `SUFeedURL`, `SUPublicEDKey` を追加
- `scripts/release.sh` の末尾で `sign_update` 実行 + `appcast.xml` 生成 + ホスト先へ push
- `scripts/build.sh` は変更不要 (Sparkle.framework は SwiftPM 経由なら Xcode が自動で embed する)

### リスク

- Sparkle.framework を embed すると codesign の対象が増える。Developer ID + notarize で問題なく通るはずだが最初のリリースで確認が要る。`codesign --verify --strict --deep` と `xcrun stapler validate` を通す
- **EdDSA 秘密鍵を失うと旧バージョンの自動アップデートが恒久的に壊れる** (新鍵で再署名した zip しか受理されない)。Dropbox 等にバックアップする運用を `docs/DEV.md` に書く
- Sparkle 2 は in-app の installer XPC を使う。`ENABLE_HARDENED_RUNTIME=YES` 環境では entitlements に `com.apple.security.cs.disable-library-validation`? それとも自動で OK? → 実装時に確認

## 実装計画

### 事前準備 [人間👨‍💻]

- [ ] Sparkle 2 の最新版番号を確認する (`https://github.com/sparkle-project/Sparkle/releases`)。SwiftPM の `from:` に渡す
- [ ] Sparkle の `generate_keys` 取得方法を決める:
  - 案 1: `brew install --cask sparkle` (`Brewfile` に追加 → `brew bundle`)
  - 案 2: Sparkle Release から `generate_keys` バイナリだけ取り出して `~/bin` に置く
  - → 推奨は **案 1** (Brewfile 経由で管理)

### Phase 1: Sparkle 組み込み + メニュー追加 (ビルド通すまで) [AI🤖]

- [x] `project.yml` に Sparkle SwiftPM 依存を追加
  - `packages:` セクションを新設 (`Sparkle: { url: https://github.com/sparkle-project/Sparkle, from: "2.9.1" }`)
  - `targets.ide.dependencies` に `- package: Sparkle` を追加
- [x] `Resources/Info.plist` に Sparkle 関連キーを追加
  - `SUFeedURL`: 空文字 (Phase 2 で確定)
  - `SUPublicEDKey`: 空文字 (鍵生成後に差し替え)
  - `SUEnableAutomaticChecks`: `<false/>` (起動時自動チェック無効)
  - `SUEnableInstallerLauncherService`: `<true/>` (Sparkle 内蔵 XPC を使う)
- [x] `Sources/ide/IdeApp.swift` で `SPUStandardUpdaterController` を保持し、メニューを追加
  - `SPUStandardUpdaterController(startingUpdater: true, ...)` を property で保持
  - `.commands { CommandGroup(after: .appInfo) { CheckForUpdatesView(updater: ...) } }` で「Check for Updates…」を追加
  - `CheckForUpdatesView` 内で `updater.canCheckForUpdates` を KVO 観測 → disabled 制御
- [x] `mise run regen && mise run build` でビルドが通ることを確認
- [x] Debug ビルドで起動し、IDE メニューに「Check for Updates…」が出ることをユーザー目視で確認
- [x] ~~Debug ビルドで「Check for Updates…」を押すと「フィード URL が不正」系のエラーダイアログが出ることを確認 (期待動作)~~ → 実際の挙動は「**メニュー項目自体が disabled (グレーアウト)**」。SUFeedURL が空文字のとき Sparkle は `canCheckForUpdates=false` を返すため。誤クリックを防げる安全側挙動なのでこのまま採用。
- [ ] コミット (Phase 1 完了)

### Phase 2 前の準備 [人間👨‍💻]

- [ ] **appcast/zip ホスト先を A / B / C から選ぶ** (Phase 1 で動作確認できた後、有償化スケジュールを見ながら決める)
- [ ] 選んだ案に応じて以下を準備:
  - 案 A: GitHub で `nyshk97/ide-releases` repo を作成 (public)。`gh repo create nyshk97/ide-releases --public`
  - 案 B: ドメイン取得 → Cloudflare R2 バケット作成 → カスタムサブドメイン設定 → 書き込み用 API トークン取得 → 1Password などに保管
  - 案 C: 何もしない (現状維持)
- [ ] `brew install --cask sparkle` を実行して `generate_keys` / `sign_update` が PATH に通ることを確認 (Brewfile にも追加)
  - `~/Library/CloudStorage/Dropbox/Brewfile` に `cask 'sparkle'` を追記
  - `brew bundle --file=~/Library/CloudStorage/Dropbox/Brewfile`
- [ ] **EdDSA 鍵ペアを生成**: `generate_keys`。秘密鍵は macOS keychain (`https://sparkle-project.org/sparkle/eddsa-public-key`) に保存される
- [ ] 公開鍵 (`generate_keys -p` の出力) を控える
- [ ] 秘密鍵を **Dropbox の安全な場所にバックアップ** (`~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-private.key` を `chmod 600`)

### Phase 2: appcast.xml 自動生成と sign_update [AI🤖]

- [ ] `Resources/Info.plist` の `SUPublicEDKey` を確定した公開鍵に差し替え
- [ ] `Resources/Info.plist` の `SUFeedURL` を確定した URL に差し替え (例: 案 A なら `https://github.com/nyshk97/ide-releases/releases/latest/download/appcast.xml`)
- [ ] `scripts/release.sh` を拡張:
  - 既存の zip 生成のあとに `sign_update build/ide.zip` を実行して EdDSA 署名と length を取得
  - `build/appcast.xml` を生成 (既存の `appcast.xml` を取得 → 新エントリを追加 → 上書き)
    - 取得元は選んだホスト先 (A: `gh release download` で旧 appcast を取り出す、B: `curl https://updates.example/ide/appcast.xml`)
  - ホスト先に push:
    - 案 A: `gh release upload --repo nyshk97/ide-releases <tag> build/ide.zip build/appcast.xml`
    - 案 B: `rclone copy build/appcast.xml r2:ide/`, `rclone copy build/ide.zip r2:ide/<version>/`
    - 案 C: 既存の `gh release create` に `build/appcast.xml` をアセットとして追加
- [ ] 1 度実リリースを試して、Sparkle が新版を検出 → ダウンロード → 自動再起動まで通ることを確認
  - 比較用に古いバージョン (例: `1.0.9`) を `/Applications/IDE.app` に置いて起動し、Check for Updates… を押す
  - 新版 (`1.0.10` 仮) をリリースしてある状態で、Sparkle がアップデートダイアログを出し、Install → 再起動まで通る
- [ ] コミット (Phase 2 完了)

### Phase 3: ドキュメント整備 [AI🤖]

- [ ] `docs/DEV.md` に「Sparkle 関連の運用」セクションを追加:
  - Sparkle 鍵生成 (`generate_keys`)
  - 秘密鍵のバックアップ場所 (Dropbox)
  - `release.sh` がどこに push するか
  - 鍵紛失時のリカバリ手順 (= ない。新鍵を発行して古いユーザーには手動再インストールを案内)
- [ ] `VERIFY.md` に Check for Updates の検証手順を追加 (実機で押す手順 + Debug ビルドでの期待エラー)
- [ ] `docs/BACKLOG.md` に「商用化時のライセンス検証/アクティベーション設計」を積む
- [ ] コミット (Phase 3 完了)

### 動作確認 [人間👨‍💻]

- [ ] Phase 1 完了時点: IDE.app を起動して `IDE > Check for Updates…` を目視確認 (メニュー存在 + Debug で押すとエラー)
- [ ] Phase 2 完了時点: 古いバージョンの IDE.app を `/Applications/` に置き直して `Check for Updates…` を押す → 新版が検出される → ダウンロード → インストール → 再起動まで完走
- [ ] Phase 3 完了時点: ドキュメントを読んで「鍵紛失時にどう動くか」が読み取れること

## ログ

### 試したこと・わかったこと

- 2026-05-14: Sparkle 2 の最新版は 2.9.1。`from: "2.9.1"` で固定
- 2026-05-14: SwiftPM 経由なら XcodeGen が自動で `IDE Dev.app/Contents/Frameworks/Sparkle.framework` を embed する。`Updater.app` と `XPCServices` も同梱されることを確認
- 2026-05-14: Debug ビルド (ad-hoc 署名) でも Sparkle.framework のリンクは通り、起動も成功

### 方針変更

- 2026-05-14: Debug 時に「押すとフィード URL エラーが出る」を期待していたが、実際は **メニュー項目自体が disabled** になる挙動だった。Sparkle が `SUFeedURL` 空のとき `canCheckForUpdates=false` を返すため。誤クリック防止の安全側挙動なのでそのまま採用 (Phase 2 で SUFeedURL を設定すると有効化される)
