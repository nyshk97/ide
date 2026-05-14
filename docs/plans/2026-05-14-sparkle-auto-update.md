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

### 決定: appcast.xml / zip のホスト先

**A 案を採用** (2026-05-14): 公開用の別 GitHub repo `nyshk97/ide-releases` を新設し public にする。本体 `nyshk97/ide` は将来 private 化可能。

- SUFeedURL: `https://github.com/nyshk97/ide-releases/releases/latest/download/appcast.xml`
- 配信 zip: `https://github.com/nyshk97/ide-releases/releases/download/v<version>/ide.zip`
- release.sh が `gh release create --repo nyshk97/ide-releases` で zip と appcast.xml をまとめてアップロード
- 本体 `nyshk97/ide` の release はソース紐付け用に従来通り (tag だけ) 残す案もあるが、Phase 2 の release.sh 改修で整理する

候補比較 (採用判断時の記録):

| 案 | 概要 | 採否 |
|---|---|---|
| A | 公開用の別 GitHub repo (`nyshk97/ide-releases`) を新設し public 化。本体 `nyshk97/ide` は将来 private 化可能 | **採用** |
| B | Cloudflare R2 + 独自サブドメイン (`updates.<domain>/ide/`)。商用化前提なら本命 | 不採用 (ドメイン/CDN 設定の初期工数を将来に倒す) |
| C | 当面 `nyshk97/ide` (public) の Release Asset を使い続け、private 化時に移行 | 不採用 (private 化時に旧 URL が 404 になり Sparkle が壊れるリスク) |

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

- [x] **appcast/zip ホスト先**: A 案 (`nyshk97/ide-releases` を新設) で確定 (2026-05-14)
- [x] ~~`~/Library/CloudStorage/Dropbox/Brewfile` の cask セクションに `cask 'sparkle'` を追記~~ → 不要。**SwiftPM が `generate_keys` / `sign_update` を `SourcePackages/artifacts/sparkle/Sparkle/bin/` に同梱**するため (homebrew cask 版は deprecated 且つ Test App のみ)。release.sh は `DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` を絶対参照する
- [ ] GitHub で `nyshk97/ide-releases` repo を作成 (public):
  ```sh
  gh repo create nyshk97/ide-releases --public --description "Update feed for IDE.app (Sparkle appcast + signed zips)"
  ```
- [ ] **EdDSA 鍵ペアを生成**: `/tmp/ide-build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`。秘密鍵は macOS Keychain に保存される (`sign_update` が自動参照)
- [ ] 公開鍵を控える: `generate_keys -p` の出力 (Base64) を Phase 2 で `SUPublicEDKey` に貼る
- [ ] 秘密鍵を **Dropbox の安全な場所にバックアップ**: `generate_keys -x ~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-private.key` → `chmod 600`

### Phase 2: appcast.xml 自動生成と sign_update [AI🤖]

- [x] `Resources/Info.plist` の `SUPublicEDKey` を `VnvTM72yjjc1FY/nzLI5uT/3mSxkOdG7k4dJqAPgZo8=` に差し替え
- [x] `Resources/Info.plist` の `SUFeedURL` を `https://github.com/nyshk97/ide-releases/releases/latest/download/appcast.xml` に設定
- [x] `scripts/build.sh` で `-derivedDataPath /tmp/ide-build-release` を固定 (release.sh が sign_update をフルパスで叩けるように)
- [x] `scripts/release.sh` を全面改修:
  - build.sh 実行後、`/tmp/ide-build-release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` で zip を EdDSA 署名
  - `https://github.com/nyshk97/ide-releases/releases/latest/download/appcast.xml` を curl で取得 (なければ template から作る)
  - python3 で `</channel>` の直前に新 `<item>` を挿入 → `build/appcast.xml`
  - `gh release create` を 2 回:
    - `nyshk97/ide`: 従来通り zip だけ (homebrew cask 互換)
    - `nyshk97/ide-releases`: zip + appcast.xml
- [x] dry-run で `sign_update` / `</channel>` 挿入ロジックを検証 (`/tmp/dummy.zip` + `/tmp/test-appcast.xml`)
- [ ] 1 度実リリースを試して、Sparkle が新版を検出 → ダウンロード → 自動再起動まで通ることを確認 (人間作業: `project.yml` の `MARKETING_VERSION` を `1.0.10` に bump → コミット → `./scripts/release.sh 1.0.10`)
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
- 2026-05-14: `homebrew-cask` の `sparkle` cask は **deprecated** で且つ「Sparkle Test App.app」しか入れない (`generate_keys` バイナリは含まれない)。一方 SwiftPM 経由でチェックアウトされた Sparkle artifact (`DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`) には `generate_keys` / `sign_update` / `BinaryDelta` が同梱されている。これを直接叩けば良い (Brewfile 不要)
- 2026-05-14: SwiftPM の DerivedData は xcodebuild がデフォルトで `~/Library/Developer/Xcode/DerivedData/<hash>/` に作るのでパスが不定。`build.sh` に `-derivedDataPath /tmp/ide-build-release` を明示して固定し、`release.sh` が `${DERIVED_DATA}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` を直接叩けるようにした
- 2026-05-14: EdDSA 公開鍵 = `VnvTM72yjjc1FY/nzLI5uT/3mSxkOdG7k4dJqAPgZo8=`。秘密鍵は macOS Keychain (`sign_update` が暗黙参照) + `~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-private.key` にバックアップ
- 2026-05-14: appcast.xml は累積運用 (過去エントリも残す) = Sparkle 標準。release.sh は `latest/download/appcast.xml` を curl で取得 → 新 `<item>` を `</channel>` 直前に挿入 → アップロードし直す
- 2026-05-14: 配信は 2 repo に zip を上げる構成にした。`nyshk97/ide` は既存の homebrew cask URL 互換のため (cask が `nyshk97/ide/releases/download/...` を参照しているので壊さない)、`nyshk97/ide-releases` は Sparkle 用に zip + appcast.xml。将来 cask の URL を ide-releases に向け直したら本体 repo の release asset は不要になる

### 方針変更

- 2026-05-14: Debug 時に「押すとフィード URL エラーが出る」を期待していたが、実際は **メニュー項目自体が disabled** になる挙動だった。Sparkle が `SUFeedURL` 空のとき `canCheckForUpdates=false` を返すため。誤クリック防止の安全側挙動なのでそのまま採用 (Phase 2 で SUFeedURL を設定すると有効化される)
