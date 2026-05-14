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
- [x] 1 度実リリースを試して、release.sh が完走することを確認 (2026-05-14 に v1.0.10 を実リリース。`ide-releases` 初回のみ手動 README push が必要だった)
- [ ] 旧版 `/Applications/IDE.app` (1.0.9) からの「Check for Updates… → 自動再起動」フロー実機検証 (人間作業: VERIFY 34-D)
- [x] コミット (Phase 2 完了)

### Phase 3: ドキュメント整備 [AI🤖]

- [x] `docs/DEV.md` の「リリース」セクションを 2-repo 配信に更新 + 「Sparkle 自前アップデート」「EdDSA 鍵」「Sparkle のツール」サブセクションを追加 (秘密鍵バックアップ場所、紛失時のリカバリ困難性、SwiftPM 同梱の `generate_keys` / `sign_update` 場所)
- [x] `VERIFY.md` に「34. Sparkle "Check for Updates…"」セクションを追加 (Sparkle 統合の自動検証、メニュー目視、release.sh ドライラン、本番リリース後の更新フロー)
- [x] `docs/BACKLOG.md` に「商用化（有償配布）を見据えた検討項目」セクションを追加 (ライセンス検証、トライアル、専用ドメイン化、本体 repo private 化、EdDSA 鍵紛失リカバリ)
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
- 2026-05-14: 初回リリース `1.0.10` 実施。本体 repo は問題なし。**`ide-releases` repo は空リポだと `gh release create` が `HTTP 422: Repository is empty.` で落ちる** ため、最小コミット (README.md) を手動 push してからリトライした。次回以降は既存コミットがあるので発生しない。release.sh は `2>&1 | tee` 越しに呼ぶと `tee` の exit code (0) が見え、本来の release.sh の失敗が見えなくなる罠あり (呼び出し側で `set -o pipefail` を有効にするか PIPESTATUS を見ること)
- 2026-05-14: notarize は Apple Notary Service で約 1-2 分。`Submission ID c173947d-7917-4a40-ab66-687271b45309` で Accepted
- 2026-05-14: **大ハマり** — `build.sh` の `zip -r -q ide.zip IDE.app` が **Sparkle.framework の symlink を実体ファイルに展開** してしまい、Gatekeeper で「壊れているため開けません」エラー。Sparkle が無かった 1.0.9 以前は plain zip で問題なかったが、framework が増えた 1.0.10 で顕在化。`build.sh` と `install.sh` を `ditto -c -k --sequesterRsrc --keepParent` / `ditto -x -k` に置き換え。原本 `/tmp/ide-export/IDE.app` (staple 済) から再 zip して GitHub の両 release の asset を入れ替え、`/Applications/IDE.app` も再インストール。EdDSA 署名は `z5DD4EomAO9srdHY1AD/anP8Mmh9uEIog1QswKzTrNXVDx01UgmxI5OlXV6Rb2fMejR3g4QKyP1mwY2uxxbZBw==` (16,421,007 bytes、ditto 圧縮で約 10% 小さくなった)
- 2026-05-14: もう 1 つの罠 — `release.sh` の `pubDate` を `date -u` で生成していたが、caller の `LANG=ja_JP.UTF-8` だと曜日 / 月名が「木, 14 5月 2026」になり Sparkle が RFC 822 として parse できない。`LC_ALL=C date` で英語固定に修正
- 2026-05-14: さらに 1 つの罠 — `project.yml` の `CURRENT_PROJECT_VERSION: "1"` が未 bump で、1.0.10 リリース後の app の `CFBundleVersion` が "1" のまま。一方 appcast には `sparkle:version="1.0.10"` を入れていたため、起動直後の Check for Updates で **app が自分自身を新版として offer** するダイアログが出た。修正: `CURRENT_PROJECT_VERSION: "$(MARKETING_VERSION)"` で連動、`release.sh` は built Info.plist から `CFBundleVersion` を読んで `sparkle:version` に入れる。1.0.10 リリースの appcast は緊急で `sparkle:version=1` に手書き修正してアップロードし直し（次回 1.0.11 からは正規ルートで通る）

### 方針変更

- 2026-05-14: Debug 時に「押すとフィード URL エラーが出る」を期待していたが、実際は **メニュー項目自体が disabled** になる挙動だった。Sparkle が `SUFeedURL` 空のとき `canCheckForUpdates=false` を返すため。誤クリック防止の安全側挙動なのでそのまま採用 (Phase 2 で SUFeedURL を設定すると有効化される)
