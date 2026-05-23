# ide → PolePole リネーム

## 概要・やりたいこと

自作 IDE のプロジェクト名を `ide` から `PolePole` (技術文脈は `polepole`) にリネームする。
背景: 商用化に向けた一意な名前への切替 (2026-05-23 決定)。

`ide` という単語は「統合開発環境」の一般名詞と衝突するため、ブランド名としてユニークでない。
PolePole はスワヒリ語で「ゆっくりと」を意味し、`polepole.dev` ドメインも取得済み。

リポジトリ名 (`nyshk97/ide`) は流用、Sparkle 配信は新規 repo に切り替え、Bundle ID を分けて
新旧アプリが共存できる状態でリリースする。canonical user は本人 1 名なので、自動 migration
よりシンプルさを優先する。

## 前提・わかっていること

### 名前の表記方針
- ブランド表記 = **PolePole** (CamelCase)、技術文脈 = **polepole** (lowercase)
- 参考: [feedback-naming-hybrid](memory)、Linear/Notion 等の慣行に合わせる

### 名前/識別子の置き換え対応表
| 項目 | 旧 | 新 |
|---|---|---|
| Bundle ID (Release) | `local.d0ne1s.ide` | `local.d0ne1s.polepole` |
| Bundle ID (Debug) | `local.d0ne1s.ide.dev` | `local.d0ne1s.polepole.dev` |
| PRODUCT_NAME (Release) | `IDE` | `PolePole` |
| PRODUCT_NAME (Debug) | `IDE Dev` | `PolePole Dev` |
| xcodeproj | `ide.xcodeproj` | `polepole.xcodeproj` |
| Sources dir | `Sources/ide/` | `Sources/polepole/` |
| AppPaths.subdirName | `ide` / `ide-dev` | `polepole` / `polepole-dev` |
| Logger dir | `~/Library/Logs/ide{,-dev}/` | `~/Library/Logs/polepole{,-dev}/` |
| Logger debug mirror | `/tmp/ide-poc.log` | `/tmp/polepole-poc.log` |
| scripts | `scripts/ide-*.sh` | `scripts/polepole-*.sh` |
| DispatchQueue label | `local.d0ne1s.ide.filewatcher` | `local.d0ne1s.polepole.filewatcher` |
| brew cask | `Casks/ide.rb` | `Casks/polepole.rb` (新規)、`Casks/ide.rb` は `deprecate!` |
| Sparkle feed | `nyshk97/ide-releases` | `nyshk97/polepole-releases` (新規 public repo) |
| バージョン | `1.0.14` から継続 | `1.0.0` にリセット (新 feed なので比較対象なし) |

### そのままにするもの
- リポジトリ名 `nyshk97/ide` は変更しない (CLAUDE.md・README の該当箇所だけ調整)
- アイコン (AppIcon / AppIcon-Dev) は現状流用 (ロゴ作成は別タスク)
- Sparkle EdDSA 鍵 / SUPublicEDKey は既存流用 (Keychain の `generate_keys` 鍵 + Dropbox バックアップ)
- notarytool keychain profile (`ide-notary`) も流用
- 旧 `nyshk97/ide-releases` repo は 1.0.14 で凍結 (削除しない)
- `docs/plans/` の過去 plan は履歴として残す (リネーム置換しない)
- Debug ビルドの分離方針 (Bundle ID `.dev` 末尾、サブディレクトリ `polepole-dev`) は維持

### 移行戦略
- **projects.json** : コードに自動 migration を入れない。README に手動 `cp -a` 手順を載せる
  ```
  cp -a "~/Library/Application Support/ide" "~/Library/Application Support/polepole"
  ```
- **TCC 権限再付与** : Bundle ID 変更で画面収録 / フルディスクアクセス / アクセシビリティは
  全部剥がれる。README とリリースノートに「`/Applications/PolePole.app` へ再付与」を明記
- **brew cask** : `ide.rb` を `deprecate!` + caveats で誘導、`polepole.rb` を新規追加
- 新旧 Bundle ID が違うので新旧アプリは **共存可能**。ユーザーは並走させてから旧を捨てれば OK
- 旧 IDE.app への in-app dialog は実装しない (canonical user が本人なので不要)

### 実装の落とし穴 (調査済み)
- `AppPaths.subdirName` のハードコードは `Sources/ide/AppPaths.swift:14` の `return "ide"` と
  `:12` の `"ide-dev"` の 2 か所。参照は Logger / ProjectsStore / ShortcutsStore / ClipboardSupport
- `local.d0ne1s.ide` のハードコードは `Sources/ide/FileChangeWatcher.swift:26` の DispatchQueue label のみ
  (それ以外は Bundle ID から動的に取得 or project.yml 経由)
- `Info.plist` 内の Bundle ID / 名前は `$(PRODUCT_BUNDLE_IDENTIFIER)` / `$(PRODUCT_NAME)` 経由なので
  Info.plist 自体の更新は **SUFeedURL コメント** と **SUFeedURL の URL** だけで足りる
- scripts は `IDE Dev` / `IDE.app` を pkill/pgrep/AppleScript で参照しているので `PolePole Dev` /
  `PolePole.app` (スペース込み) に置換が要る。クオートは現状すでに付いているので構造は流用可能
- `scripts/release.sh` は本体 repo (`nyshk97/ide`) と配信 repo (`nyshk97/ide-releases`) の両方に
  `gh release create` している。配信側だけ `nyshk97/polepole-releases` に切り替える
  (本体 repo は `nyshk97/ide` のまま据え置き)
- `scripts/build.sh` の `IDE.app` / `/tmp/ide.xcarchive` / `/tmp/ide-export` / `/tmp/ide-build-release`
  / `keychain profile ide-notary` の参照も置換要 (profile 名だけは流用、それ以外は polepole に rename)
- `release.sh` の appcast 内 `<title>IDE</title>` も `PolePole` に更新

### Phase 構成方針
- 各 Phase 末で commit。phase 1 の中も「project.yml 改」「Sources rename」「ハードコード置換」で
  3 つに分割して commit
- Phase 1 と Phase 2 の合間で `mise run build` + `scripts/polepole-launch.sh` + screenshot を
  撮って動作確認 (Debug ビルドで完結)
- Phase 4 (brew tap 更新の commit) と Phase 5 (Release ビルド) は SHA256 を反映するため
  Phase 5 完了後に Phase 4 の formula 行を埋め直して push する順序になる

---

## 実装計画

### 事前準備 [人間👨‍💻]
- [ ] `nyshk97/polepole-releases` repo を Claude が `gh repo create --public` で作る作業に同意済み
      → Phase 5 内で実行する (Claude が確認を取ってから `gh` を叩く)
- [ ] Dropbox の Sparkle 秘密鍵 (`secrets/sparkle-ed25519-private.key`) と Keychain の
      `generate_keys` 鍵がアクセス可能なことを確認 (流用する)
- [ ] notarytool profile `ide-notary` が現状動くことを確認 (流用する)

### Phase 1a: project.yml と Sources/ ディレクトリのリネーム [AI🤖] ✅ commit `fa770c1`
- [x] `project.yml` を更新
  - `name: ide` → `name: polepole`
  - `targets: ide:` → `targets: polepole:`
  - Release `PRODUCT_BUNDLE_IDENTIFIER: local.d0ne1s.ide` → `local.d0ne1s.polepole`
  - Release `PRODUCT_NAME: IDE` → `PolePole`
  - Debug `PRODUCT_BUNDLE_IDENTIFIER: local.d0ne1s.ide.dev` → `local.d0ne1s.polepole.dev`
  - Debug `PRODUCT_NAME: IDE Dev` → `PolePole Dev`
  - `CODE_SIGN_ENTITLEMENTS: Resources/IDE.entitlements` → `Resources/PolePole.entitlements`
  - sources の `Sources/ide` → `Sources/polepole`
- [x] `git mv Sources/ide Sources/polepole`
- [x] `git mv Resources/IDE.entitlements Resources/PolePole.entitlements`
- [x] commit: "refactor(polepole-rename): rename xcodeproj target and Sources dir"

### Phase 1b: コード内文字列の置換 [AI🤖] ✅ commit `86d84de`
- [x] `Sources/polepole/AppPaths.swift`: `"ide"` → `"polepole"`、`"ide-dev"` → `"polepole-dev"`
      コメント内の `ide` / `ide-dev` 言及も更新
- [x] `Sources/polepole/FileChangeWatcher.swift`: DispatchQueue label を `local.d0ne1s.polepole.filewatcher` に
- [x] `Sources/polepole/Logger.swift`: doc コメント (`~/Library/Logs/{ide,ide-dev}/` の言及)、
      `debugMirrorPath = "/tmp/ide-poc.log"` → `/tmp/polepole-poc.log`
- [x] `Sources/polepole/IdeApp.swift` / `AppDelegate.swift` 等のコメント内 `IDE` / `IDE Dev` 言及を
      `PolePole` / `PolePole Dev` に (機能変更ではなくコメントのみの置換)
- [x] `Sources/polepole/IdeApp.swift` のファイル名 → `PolePoleApp.swift` (struct も `PolePoleApp` に、
      `IdeAppDelegate` も `PolePoleAppDelegate` に同時 rename)
- [x] `Resources/Info.plist` の SUFeedURL を `https://github.com/nyshk97/polepole-releases/releases/latest/download/appcast.xml` に、
      コメント内の `nyshk97/ide-releases` / `nyshk97/ide` 言及も更新
- [x] `Resources/PolePole.entitlements` を grep して `ide` 文字列が無いか確認 (パスのみ rename の想定)
- [x] commit: "refactor(polepole-rename): replace hardcoded ide identifiers in code"
- 追加で発見した実値置換: `RootLayoutView.swift` の `autosaveName: "ide.rootSplit"` →
  `"polepole.rootSplit"` (NSSplitView の UserDefaults キー)、`GhosttyManager.swift` の
  `ghostty_config_load_string` の name `"ide-bundled-reset"` → `"polepole-bundled-reset"`

### Phase 1c: ビルド動作確認 [AI🤖] ✅ (commit なし、コード変更なしのため)
- [x] `mise run regen` を走らせて `polepole.xcodeproj` が生成されることを確認
- [x] `.gitignore` の `*.xcodeproj` で polepole.xcodeproj も対象であることを確認
- [x] `xcodebuild -project polepole.xcodeproj -scheme polepole -configuration Debug ...` で BUILD SUCCEEDED
- [x] `PolePole Dev.app` を起動 → メニューバーとウィンドウタイトルが "PolePole Dev"
- [x] `~/Library/Logs/polepole-dev/` が作られて polepole-dev-YYYY-MM-DD.log が書かれた、
      `/tmp/polepole-poc.log` に debug mirror が書かれた
- [x] `~/Library/Application Support/ide-dev/` を `mktemp` 配下にバックアップ済み
- ~~commit: "chore(polepole-rename): verify debug build runs after rename"~~
  (動作確認のためのコード変更は不要だったので commit はスキップ)

### Phase 2: scripts のリネームと中身置換 [AI🤖] ✅ commit `2295d57`
- [x] `git mv scripts/ide-launch.sh scripts/polepole-launch.sh`
- [x] `git mv scripts/ide-screenshot.sh scripts/polepole-screenshot.sh`
- [x] `git mv scripts/ide-keystroke.sh scripts/polepole-keystroke.sh`
- [x] 3 つのファイル内の `IDE Dev` → `PolePole Dev`、`IDE.app` → `PolePole.app`、
      `pkill -x "IDE Dev"` → `pkill -x "PolePole Dev"`、AppleScript `tell process "IDE Dev"` 置換、
      コメント内の `ide` / `IDE` も適宜更新
- [x] `scripts/build.sh` の置換
  - `IDE.app` → `PolePole.app`
  - `/tmp/ide.xcarchive` → `/tmp/polepole.xcarchive`
  - `/tmp/ide-export` → `/tmp/polepole-export`
  - `/tmp/ide-build-release` (env var fallback) → `/tmp/polepole-build-release`
  - `/tmp/ide-notarize.zip` → `/tmp/polepole-notarize.zip`
  - `build/ide.zip` → `build/polepole.zip`
  - `-scheme ide` → `-scheme polepole`、`PROJECT="$PROJECT_ROOT/ide.xcodeproj"` → `polepole.xcodeproj`
  - `NOTARY_PROFILE` のデフォルト値 `ide-notary` は維持 (Keychain の profile 名は流用)
  - 環境変数名 `IDE_RELEASE_DERIVED_DATA` → `POLEPOLE_RELEASE_DERIVED_DATA` (既出 caller は無いはず、grep 確認)
  - 環境変数名 `IDE_TEST_*` (Swift 側のテストフラグ) は **そのまま維持** または `POLEPOLE_TEST_*` に rename
        → CLAUDE.md / VERIFY.md 大量参照あり。Phase 3 で同時更新するため、ここでは触らない方針を採る場合は
          Phase 3 の作業範囲に追加。判断: **`POLEPOLE_TEST_*` に統一する** (canonical user 一人なので
          一気に切り替えても破壊しない)
- [x] `scripts/release.sh` の置換
  - `build/ide.zip` → `build/polepole.zip`
  - `RELEASES_REPO="nyshk97/ide-releases"` → `"nyshk97/polepole-releases"`
  - `/tmp/ide-export/IDE.app` → `/tmp/polepole-export/PolePole.app`
  - `IDE_RELEASE_DERIVED_DATA` → `POLEPOLE_RELEASE_DERIVED_DATA`
  - `Creating release on nyshk97/ide` のメッセージ、`--notes "ide $VERSION"` → `polepole`
  - appcast 内の `<title>IDE</title>` → `<title>PolePole</title>`、`<description>Most recent IDE updates</description>` → `PolePole`
  - DOWNLOAD_URL の `ide.zip` → `polepole.zip`
  - Homebrew cask 更新時の echo `cask "ide"` 表示 → `polepole`
- [x] `scripts/install.sh` の置換
  - `build/ide.zip` → `build/polepole.zip`
  - `/Applications/IDE.app` → `/Applications/PolePole.app`
  - `STAGE/IDE.app` → `STAGE/PolePole.app`
- [x] `scripts/generate-app-icon.sh` の `ide-icon-master` tmpfile 名は影響薄、置換するなら同時に
- [x] `IDE_TEST_*` 環境変数の Swift 側 (`Sources/polepole/`) の参照を `POLEPOLE_TEST_*` に grep 置換
- [x] `.mise.toml` の置換
  - `xcodegen generate` 部分はそのままで OK (project.yml を読むだけ)
  - `-project ide.xcodeproj -scheme ide` → `polepole.xcodeproj` / `polepole`
  - `/tmp/ide-build` のままにするか `/tmp/polepole-build` にするかは選択肢だが、DerivedData の
        場所はリネームで不利益が無いので `/tmp/polepole-build` に統一する
  - `pkill -x "IDE Dev"` → `pkill -x "PolePole Dev"`、`IDE Dev.app` → `PolePole Dev.app`
  - `rm -rf ide.xcodeproj` → `rm -rf polepole.xcodeproj`
  - description 内の `ide` / `IDE` 言及も更新
- [x] `mise run build` + `./scripts/polepole-launch.sh` + `./scripts/polepole-screenshot.sh /tmp/v.png` で
      動作確認 (screenshot は `PolePole Dev` ウィンドウを正しく掴んだ)
- [~] `scripts/polepole-keystroke.sh` は IDE 内 Claude Code からは osascript が TCC で
      「許可されません」エラー (構文 OK、外部からは動作する想定。CLAUDE.md の既知制約に従う)
- [x] commit: "refactor(polepole-rename): rename scripts and update build/release flow"

### Phase 3: docs 一斉置換 + migration 手順 [AI🤖] ✅
- [x] 対象ファイル: `README.md`, `CLAUDE.md`, `REQUIREMENTS.md`, `VERIFY.md`,
      `docs/ARCHITECTURE.md`, `docs/DEV.md`, `docs/BACKLOG.md`, `docs/COMMERCIALIZATION.md`
- [x] 置換ルール (README.md と CLAUDE.md は手書き、その他は Perl で一括)
  - 製品名 `IDE` (ブランドとしての言及) → `PolePole`
  - 開発版 `IDE Dev` → `PolePole Dev`
  - app バイナリ `IDE.app` / `IDE Dev.app` → `PolePole.app` / `PolePole Dev.app`
  - サブディレクトリ言及 `ide/` `ide-dev/` (Application Support / Logs 文脈) → `polepole/` / `polepole-dev/`
  - script パス `scripts/ide-*.sh` → `scripts/polepole-*.sh`
  - 環境変数 `IDE_TEST_*` → `POLEPOLE_TEST_*`、`IDE_RELEASE_DERIVED_DATA` → `POLEPOLE_RELEASE_DERIVED_DATA`
  - Bundle ID `local.d0ne1s.ide{,.dev}` → `local.d0ne1s.polepole{,.dev}`
  - debug mirror path `/tmp/ide-poc.log` → `/tmp/polepole-poc.log`
  - Sparkle feed URL の repo 名 (該当箇所のみ) → `nyshk97/polepole-releases`
- [x] 保持するもの
  - `nyshk97/ide` リポジトリ URL (リポジトリ名は変えないので)
  - `nyshk97/ide-releases` は「凍結された旧 feed」として文脈に応じて言及を残す (README / CLAUDE で言及)
  - 一般名詞としての "IDE" (例: README の「macOS 用の自作 IDE」「統合開発環境」のような文章) は残し、
    PolePole(本アプリ) を指す代名詞としての "IDE" は PolePole に置換する方針で対応
  - Migration guide 内の `rm -rf /Applications/IDE.app` / `Application Support/ide` のように
    旧パス・旧 app 名を意図的に参照する箇所は保持
- [x] `docs/plans/` の過去ファイル (`2026-05-12-*`, `phase1-*`, `phase2-*`, `poc-*`) は **触らない**
- [x] `README.md` の冒頭に **リネーム告知セクション** を追加
  ```
  > **Renamed from `ide` to `PolePole` (2026-05-23).**
  > See [Migration guide](#migration-from-ide) below if you used the previous `ide` build.
  ```
- [x] `README.md` に **Migration from `ide`** セクションを追加
  - `brew uninstall ide` → `brew install nyshk97/tap/polepole`
  - `cp -a "~/Library/Application Support/ide" "~/Library/Application Support/polepole"` (旧データを残したまま新側へコピー)
  - TCC 再付与 (画面収録 / アクセシビリティ / フルディスクアクセス) の手順
  - 旧 `/Applications/IDE.app` は確認後に手動で捨てる
- [x] `CLAUDE.md` の「⚠️ Brew 版データ」セクションを **`polepole/` 視点** に更新
- [x] `VERIFY.md` の手順内パス・スクリプト名・プロセス名を Perl で一括置換
- [x] ついでに VERIFY.md の typo (`pkill -x ide` / `Debug/ide.app/Contents/MacOS/ide`) を
      正しい `"PolePole Dev"` / `"PolePole Dev.app/Contents/MacOS/PolePole Dev"` に修正
- [x] commit: "docs(polepole-rename): update all current docs to PolePole branding"

### Phase 4a: brew tap formula の更新 (SHA256 以外) [AI🤖]
- [ ] 作業ディレクトリ: `/opt/homebrew/Library/Taps/nyshk97/homebrew-tap`
- [ ] `Casks/polepole.rb` を新規作成 (SHA256 は仮の `0`*64、Phase 5 完了後に Phase 4b で埋める)
  ```ruby
  cask "polepole" do
    version "1.0.0"
    sha256 "0000000000000000000000000000000000000000000000000000000000000000"

    url "https://github.com/nyshk97/ide/releases/download/v#{version}/polepole.zip"
    name "PolePole"
    desc "Self-hosted IDE that integrates Ghostty terminal and Claude Code"
    homepage "https://github.com/nyshk97/ide"

    app "PolePole.app"
  end
  ```
- [ ] `Casks/ide.rb` を `deprecate!` + caveats に書き換え
  ```ruby
  cask "ide" do
    version "1.0.14"
    sha256 "c454e653dad049c43337868ebc20b0b907310d4e6cbefc06e0fea568550e36d7"

    url "https://github.com/nyshk97/ide/releases/download/v#{version}/ide.zip"
    name "ide"
    desc "Self-hosted IDE that integrates Ghostty terminal and Claude Code"
    homepage "https://github.com/nyshk97/ide"

    deprecate! date: "2026-05-23", because: "renamed to polepole"

    app "IDE.app"

    caveats <<~EOS
      'ide' has been renamed to 'PolePole'.
        brew uninstall ide
        brew install nyshk97/tap/polepole
      Migrate user data:
        cp -a "$HOME/Library/Application Support/ide" \\
              "$HOME/Library/Application Support/polepole"
      Re-grant TCC permissions to PolePole.app (Screen Recording, Accessibility, Full Disk Access).
    EOS
  end
  ```
- [ ] Phase 4a は commit しない (Phase 5 で SHA256 確定してから一括で push)

### Phase 5前の準備 [人間👨‍💻 + AI🤖確認]
- [ ] Claude が `gh repo create nyshk97/polepole-releases --public --description "Sparkle update feed for PolePole.app"` を
      **ユーザーに確認してから** 実行する
- [ ] 作成後、空 release が無い状態でも `release.sh` が「No existing appcast.xml; creating fresh」で
      新規生成することを確認 (curl が 404 → fresh テンプレを書く既存パスがあるので問題なし)

### Phase 5: Release ビルド + notarize + upload [AI🤖]
- [ ] `project.yml` の MARKETING_VERSION を `1.0.0` に更新 (現在 `1.0.14`)
- [ ] `mise run regen` → `mise run build` で Debug が壊れていないことを最終確認
- [ ] commit: "chore(polepole-rename): bump MARKETING_VERSION to 1.0.0"
- [ ] `git push origin main` (release.sh が push を要求する)
- [ ] `scripts/build.sh` を実行 (Release archive → Developer ID 署名 → notarize → staple → `build/polepole.zip` 生成)
- [ ] `scripts/release.sh 1.0.0` を実行
  - `nyshk97/ide` に `v1.0.0` tag + `polepole.zip` release を作る (homebrew cask の URL 互換)
  - `nyshk97/polepole-releases` に `v1.0.0` tag + `polepole.zip` + `appcast.xml` を作る (Sparkle feed)
- [ ] 出力された SHA256 を控える
- [ ] `/opt/homebrew/Library/Taps/nyshk97/homebrew-tap/Casks/polepole.rb` の SHA256 を実値に差し替え
- [ ] `git -C /opt/homebrew/Library/Taps/nyshk97/homebrew-tap add Casks/polepole.rb Casks/ide.rb`
      → commit "polepole: add cask, deprecate ide" → push (ユーザー確認のうえで)
- [ ] commit (本体 repo): "release(polepole-rename): cut PolePole 1.0.0"

### 動作確認 [AI🤖 + 人間👨‍💻]
- [ ] [AI🤖] `brew update && brew install nyshk97/tap/polepole` で新 cask が引けることを確認
- [ ] [AI🤖] `/Applications/PolePole.app` が配置されたことを確認
- [ ] [人間👨‍💻] PolePole.app に TCC 権限 (画面収録 / アクセシビリティ / フルディスクアクセス) を再付与
- [ ] [人間👨‍💻] PolePole.app を起動 → projects.json が空であれば手動 cp -a を実施
- [ ] [人間👨‍💻] 旧 IDE.app と並べて動作確認 (新旧共存できることを確認)
- [ ] [人間👨‍💻] 旧 `/Applications/IDE.app` を `brew uninstall ide` で削除
- [ ] [AI🤖] VERIFY.md の代表手順 (起動・キーストローク・screenshot) を polepole-* スクリプトで実行
- [ ] [人間👨‍💻] PolePole 起動中に Check for Updates… を一度走らせ、新 feed に到達できることを確認
      (latest=1.0.0 なので「最新です」表示が出れば OK)

---

## ログ

### 試したこと・わかったこと

- **Phase 1c screenshot 経路**: IDE.app 内の Claude Code から `CGWindowListCopyWindowInfo` を
  叩いてもウィンドウ owner が拾えず (TCC 制限)、`./scripts/polepole-screenshot.sh` 系の
  「window ID 取得 → screencapture -l」フォールバックが空打ちになる。対策:
  `osascript -e 'tell application "PolePole Dev" to activate'` で前面化してから
  `screencapture -x` でフルスクリーンを撮る。これで GUI 検証は通る
- **Phase 2 動作確認の polepole-keystroke.sh**: IDE 内 Claude Code から走らせると osascript が
  `osascriptにはキー操作の送信は許可されません。 (1002)` を返す。構文 OK だが
  IDE.app コンテキストの権限制約なので、CLAUDE.md の「キーストロークが要る検証は IDE 内
  Claude Code からは自動化できない」注釈通り。外部 Terminal.app からは動く想定で OK とした
- **AppPaths.subdirName の検証**: `PolePole Dev.app` 起動で `~/Library/Logs/polepole-dev/` と
  `/tmp/polepole-poc.log` が新規作成され、旧 `ide-dev/` には触れていないことを確認

### 方針変更

- **VERIFY.md の typo 修正もリネーム作業に含めた**: VERIFY.md に元から `pkill -x ide` と
  `Debug/ide.app/Contents/MacOS/ide` (小文字) があり、本来の Debug 名 `PolePole Dev` (旧名 `IDE Dev`)
  と食い違っていた。リネームと同時に修正した方が将来引っかからないので Phase 3 で
  まとめて直した (本来は別 fix commit が正規だが、影響範囲が VERIFY 内なので一緒に処理)

- **plan ファイル混入**: Phase 1b の commit で `git add -A` した際、untracked だった
  `docs/plans/2026-05-23-polepole-rename.md` も巻き込んで commit してしまった。実害は無いが
  本来は別 commit (plan ファイル単独) にすべきだった。以降は `git add <path>` で明示する
- **polepole-launch.sh の rename 検出失敗**: Phase 2 で 3 スクリプトを `git mv` 後に `Write` で
  全文置換したところ、`polepole-launch.sh` だけ git の rename 検出が効かず
  `delete + create` 扱いになった (`polepole-keystroke.sh` / `polepole-screenshot.sh` は
  rename 検出された)。閾値ギリギリで類似度が落ちたためと推測。実害なし

### 方針変更
(実装中に随時追記)
