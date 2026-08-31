# DEV

開発時に頻繁に使うコマンド・ヘルパ・落とし穴の集約。手元から離れて戻ってきたときに 30 秒で再開できることを目指す。

---

## 前提環境

- macOS 14+ / Apple Silicon
- Xcode（Swift 6 strict concurrency が通る版）
- mise（[XcodeGen](https://github.com/yonaskolb/XcodeGen) を mise 経由で取る）

ホスト初回セットアップは [Brewfile](../../Brewfile) を参照（dotfiles 側）。

---

## ビルドと起動

| 用途 | コマンド |
|---|---|
| ビルド | `mise run build` |
| 起動（kill + open） | `./scripts/polepole-launch.sh` |
| ビルド + 起動 | `mise run run` |
| `xcodeproj` 再生成のみ | `mise run regen` |
| クリーン | `mise run clean`（DerivedData + polepole.xcodeproj を消す） |

`mise run build` は内部で `regen` を依存に持つので、新規 `.swift` ファイルを追加した直後でも忘れずに pickup される。

ビルド成果物は `/tmp/polepole-build/Build/Products/Debug/ide.app`。

---

## リリース

1. `docs/CHANGELOG.md` の `[Unreleased]` を埋めてコミット（各項目は `- ja: ...` / `- en: ...` のペア。ユーザー目視で気づく変更だけ。書き方は CHANGELOG 冒頭）。`git log <前回タグ>..HEAD` を読んで Claude Code のセッションが書く。空のまま叩くと止まる
2. `mise run release [patch|minor|major|x.y.z]`（既定 patch）を実行（Claude Code のセッションから叩いてよい。対話は無い）
   - preflight（gh 認証・clean worktree・origin/main と一致・Release 未作成・画面ロック・notary プロファイル・Sparkle 鍵）
   - `[Unreleased]` → `[<version>] - <date>` にリネームし、`project.yml` の `MARKETING_VERSION` を `<version>` に揃えて 1 commit（`CURRENT_PROJECT_VERSION` は `$(MARKETING_VERSION)` で連動）。push 前に失敗したら trap で巻き戻る
   - 該当 section を抜き出して GitHub Release notes (ja/en 両方の md) と Sparkle appcast の `<description>` (ja のみの HTML) を自動生成 → release/feed に投入
   - Release ビルド（Developer ID 署名 + notarize + staple）→ `git push origin main` → `nyshk97/polepole-releases` に dmg + `appcast.xml` を上げる（本体 repo `nyshk97/ide` には release を作らない。旧 ide 配布の履歴は凍結）
   - `sign_update` で dmg を **EdDSA 署名** し、過去の `appcast.xml` を取得 → 新 `<item>` を `</channel>` 直前に挿入してアップロードする（累積）
   - `nyshk97/homebrew-tap/Casks/polepole.rb` の `version` / `sha256` を更新し、ローカル tap を pull
3. notarize / codesign の timestamp や `gh release upload` がネットワークを使うので **Bash サンドボックスを無効化して**走らせる（下の「`scripts/build.sh` はネットワークが要る」参照）
4. ローカルに最新版を入れる → **`scripts/install.sh`**（`/Applications/PolePole.app` をバンドルごと差し替え）

**dogfooding 中（PolePole.app の中で Claude Code を回している）に `brew upgrade --cask ide` を打つと、cask が実行中の PolePole.app を quit してそのセッションごと死ぬ**。`scripts/install.sh` はバンドルを上書きするだけで実行中プロセスは生かしたまま（macOS は使用中の .app バンドルを unlink してもプロセスは動き続ける）なので、こちらを使う。どちらにしても修正の反映には PolePole.app の手動再起動が必要。`install.sh` 経由だと `brew` 側のバージョン表示はズレるが実害なし（次に `brew upgrade --cask ide` を打てば揃う）。

### Sparkle 自前アップデート

メニュー > `PolePole` > `Check for Updates…` から手動で更新できる（要件「起動時に通信しない」を満たすため自動チェックは無効。`SUEnableAutomaticChecks=false`）。

- **配信フィード URL**: `https://github.com/nyshk97/polepole-releases/releases/latest/download/appcast.xml`
- **配信 zip URL**: `https://github.com/nyshk97/polepole-releases/releases/download/v<version>/ide.zip`
- 配信用 repo（`nyshk97/polepole-releases`）は **public** 必須。Sparkle は匿名で curl する。本体 repo（`nyshk97/ide`）は将来 private 化しても更新フィードは動く

### EdDSA 鍵

### Sparkle は `CFBundleVersion` で比較する（MARKETING_VERSION と連動させる）

Sparkle の version 比較は appcast の `sparkle:version` と app の `CFBundleVersion` で行う（`shortVersionString` は表示用）。`CFBundleVersion` (= `CURRENT_PROJECT_VERSION`) を bump しないと、新版 zip を配っても「現バージョンと同じ」と判定されたり、逆に **app が自分自身を新版として offer** する（1.0.10 リリース後に CFBundleVersion=1 のままだと「build 1 のユーザーに 1.0.10 を案内」が初回 Check で発火する）。

そのため `project.yml` は `CURRENT_PROJECT_VERSION: "$(MARKETING_VERSION)"` で連動させてある。bump 時は `MARKETING_VERSION` だけ書き換えれば足りる。`release.sh` は built `.app/Contents/Info.plist` から `CFBundleVersion` / `CFBundleShortVersionString` を直接読んで appcast に書く（sanity check 付き）。

### `build.sh` の zip 化と `install.sh` の展開は `ditto` を使う（`zip` / `unzip` ではない）

`Sparkle.framework` は **シンボリックリンクで構成された framework バンドル**（`Resources -> Versions/Current/Resources` など）。`zip -r` のデフォルトは symlink を辿って実体ファイルに展開してしまい、framework 構造を壊す（codesign が "bundle format is ambiguous (could be app or framework)" を返し、Gatekeeper は「壊れているため開けません。ゴミ箱に入れる必要があります」を出す）。

そのため:
- ビルド側: `ditto -c -k --sequesterRsrc --keepParent PolePole.app ide.zip`
- インストール側: `ditto -x -k ide.zip <dest>`

を使う。**Sparkle が embed されていなかった旧バージョン (1.0.9 以前) は plain zip でも動いていたが、Sparkle.framework が入った 1.0.10 から罠が顕在化**。同じ理由で `release.sh` 内の pubDate は `LC_ALL=C date` で英語に固定する（`LANG=ja_JP` だと「木, 14 5月 2026」になり Sparkle が parse 失敗する）。

### EdDSA 鍵

- 公開鍵は `Resources/Info.plist` の `SUPublicEDKey` に Base64 で埋まっている: `VnvTM72yjjc1FY/nzLI5uT/3mSxkOdG7k4dJqAPgZo8=`
- ペアの秘密鍵は **macOS Keychain** に保存されている（`sign_update` が暗黙的に参照する）
- 安全のため `~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-private.key`（`chmod 600`）にバックアップ
- **秘密鍵を失うと、旧バージョンに配ったユーザーの自動アップデートが恒久的に壊れる**（新鍵で署名し直した zip は受理されない）。新鍵を作ってリリースしても、ユーザー側は手動で新版 PolePole.app を入れ直すまで詰む。Dropbox バックアップは消さないこと

### Sparkle のツール（generate_keys / sign_update）

SwiftPM が落としてくる artifact 内に同梱されている（`homebrew-cask` の `sparkle` は deprecated 且つ Test App しか入れないので使わない）:

```
/tmp/polepole-build-release/SourcePackages/artifacts/sparkle/Sparkle/bin/
├── generate_keys     # 鍵ペア生成（一度だけ。Keychain 登録）
├── sign_update       # zip を EdDSA 署名（release.sh が自動で叩く）
└── BinaryDelta       # 差分更新の生成（今は使わない）
```

`build.sh` が `-derivedDataPath /tmp/polepole-build-release` を固定しているので、`release.sh` からはこの絶対パスで `sign_update` を直接呼べる。`mise run build` の DerivedData は `/tmp/polepole-build` で別なので注意（こっちで `generate_keys` を叩く分には問題ない）。

---

## 動作確認スクリプト

| スクリプト | 用途 |
|---|---|
| `scripts/polepole-launch.sh [wait_seconds]` | ide を kill してから起動。デフォルト 3 秒待機 |
| `scripts/polepole-keystroke.sh [--enter|--keycode N] "text"` | osascript（補助アクセス権限が必要）でキー送信 |
| `scripts/polepole-screenshot.sh <path>` | `CGWindowList` でウィンドウ ID を引いて `screencapture -l` でキャプチャ（取れなければメイン画面全体にフォールバック） |

### TCC（プライバシー）権限の罠

「PolePole の中で PolePole を開発する」（PolePole 内ターミナルで Claude Code を動かす）には、`/Applications/PolePole.app` に下記 2 つの TCC 許可が必須。Release ビルドは安定した Developer ID 署名（固定 team `VYDUR99LAM` / bundle ID `local.d0ne1s.polepole` / `CODE_SIGN_STYLE: Manual`）なので、一度付与すれば **brew 更新を跨いで残る**。macOS アップデート等で剥がれたら再付与（→ いずれも `PolePole.app` を Cmd+Q & 再起動。TCC は起動時に読まれる）。

- **画面収録（`screencapture` / `ide-screenshot.sh`）が要るもの**:
  `screencapture` の TCC「責任プロセス」は、起動したプロセスのツリーを遡って最初の非システムバイナリに解決される。**PolePole 内で Claude Code を動かしている場合は `PolePole.app` 自身**（`login` でも `claude.exe` でもない。プロンプトも「"PolePole.app" でこのコンピュータの画面を記録しようとしています」と出る）。なので **System Settings → プライバシーとセキュリティ → 画面収録 に `/Applications/PolePole.app` を追加して ON**。剥がれたらリストから `PolePole.app` を削除 → `screencapture`（or `ide-screenshot.sh`）を再実行 → 出た再プロンプトの「システム設定を開く」→ 新規追加された `PolePole.app` を ON → PolePole.app 再起動。
  - `ide-screenshot.sh` は `osascript` を捨てて `CGWindowList`（補助アクセス不要）+ `screencapture -l` にしてあるので「アクセシビリティ」は不要、「画面収録」だけでよい。
  - Claude Code を **PolePole の外**（素の Terminal.app 等）から動かしている場合は責任プロセスがその端末アプリ（or `claude.exe`）になるので、そっちに画面収録を付与する必要がある。`claude.exe`（`com.anthropic.claude-code`）は CUI でプロンプトを出せないため、その経路だと「could not create image from display」と無言で失敗する。
- **フルディスクアクセス（`~/.zshrc` 等の dotfiles 読み込み）が要るもの**:
  dotfiles は実体が `~/Library/CloudStorage/Dropbox/dotfiles/` にあり symlink で配置されている（`~/.claude/CLAUDE.md` 参照）。`~/Library/CloudStorage/` 配下は TCC 保護なので、**`PolePole.app` にフルディスクアクセスが無いと PolePole 内ターミナルのログインシェルが `~/.zshrc` を辿れず `EPERM`（`source: operation not permitted`）で無言スキップ** → デフォルトプロンプト・mise 未起動・`claude` not found になる（subprocess は `PolePole.app` の責任プロセス属性を継ぐので Claude Code も巻き込まれる）。**System Settings → プライバシーとセキュリティ → フルディスクアクセス に `/Applications/PolePole.app` を追加して ON**（→ PolePole.app 再起動）すれば直る。PolePole 内 Claude Code が `~/Library/CloudStorage/Dropbox/` の `Brewfile` / `dotfiles/` / `settings/` を読むのにも必要。
- **アクセシビリティ（`osascript` / `ide-keystroke.sh`）は PolePole 内では諦める**:
  合成キー入力には `osascript` の補助アクセスが要るが、PolePole 内ターミナルは `/usr/bin/login` 経由でシェルを起動するため TCC 責任プロセスが `PolePole.app` に解決されず（ここだけ `login` が効く）、`osascript` 自体に毎回ポップアップが出る（恒久付与できない）。スクショ自体は `ide-screenshot.sh` が `osascript` を使わないので影響しないが、`ide-keystroke.sh`（キーストローク送信）が要る検証だけは Terminal.app / iTerm から `claude` を起動して回す（普通に署名された安定アプリ & `login` 介在なしで付与が効き続ける）。

- **`scripts/build.sh`（Release ビルド）はネットワークが要る**: codesign の `--timestamp`（`timestamp.apple.com`）や `xcrun notarytool`（Apple）が、Claude Code の Bash サンドボックスだと不達で落ちる（`A timestamp was expected but was not found` 等）。エージェントから走らせるときは Bash ツールのサンドボックスを無効化する。これ自体は人間検証向け。

詳しい確認手順は [VERIFY.md](../VERIFY.md)。

---

## テスト用環境変数

VERIFY 用に起動時の状態を仕込めるフラグ。**本番ユーザーは設定しない**前提。
すべて `~/Library/Application Support/polepole-dev/projects.json` にピン留めが事前に書かれていることを前提にする。

| 環境変数 | 効果 |
|---|---|
| `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=N` | 起動時に N 番目のピン留めをアクティブ化（要件「再起動時は active を復元しない」を VERIFY で迂回するため） |
| `POLEPOLE_TEST_AUTO_PREVIEW=<rel-path>` | active project からの相対パスでプレビューを開く |
| `POLEPOLE_TEST_AUTO_QUICKSEARCH=<query>` | 起動時に Cmd+P の overlay を開いてクエリを入力した状態にする |
| `POLEPOLE_TEST_AUTO_FULLSEARCH=<query>` | 起動時に Cmd+Shift+F の overlay を開いて grep を実行（TextField.onSubmit が AppleScript の Enter で発火しないため） |
| `POLEPOLE_TEST_PREVIEW_FIND=<query>` | `POLEPOLE_TEST_AUTO_PREVIEW` でプレビューを開いた状態で Cmd+F のファイル内検索バーを開き、`<query>` をハイライトする |
| `POLEPOLE_TEST_TOAST=<message>` | 起動時に赤 toast を出す |
| `POLEPOLE_TEST_UNREAD_INDICES=0,2` | 起動時に N 番目（allOrdered = pinned + temporary）のプロジェクトの workspace を作り、下ペインのカレントタブに未読通知を立てる（サイドバーのリング表示の検証用）。`POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` と同じインデックスを指すと「アクティブ化でその表示タブの未読が消える」挙動も確認できる |
| `POLEPOLE_TEST_AUTO_OPEN_DIFF=1` | 起動時に active project の diff overlay (Cmd+D) を自動で開く。`git diff` の取得は非同期なので screenshot 前に sleep を入れる |
| `POLEPOLE_TEST_SIDEBAR_COLLAPSED=1` | 起動時に左サイドバー（プロジェクト一覧）を折りたたみ状態にする。値は `1` または `true` を受ける。`Cmd+S` で同等のトグル（リバインド可能） |
| `POLEPOLE_TEST_AUTO_EMPTY_HUB=1` | プロジェクトが何件かあっても中央ペインを EmptyHubView (`Get started` 画面) に差し替える。実 `projects.json` を空にする破壊的検証を避けたいときに使う。値は `1` または `true` |
| `POLEPOLE_TEST_IMPORT_FIXTURE=<dir>` | Import 機能の全 source の参照先を fixture ディレクトリに差し替える。期待構造: `<dir>/conventional/`（`.git` 含むツリー）、`<dir>/cmux/session.json`、`<dir>/tmuxinator/*.yml`、`<dir>/vscode/storage.json`、`<dir>/cursor/storage.json`。各ファイル / ディレクトリは存在しなくて良い（無いものは静かにスキップ） |
| `POLEPOLE_TEST_AUTO_FSEVENTS_PROBE=<filename>` | FileIndex (Cmd+P) の FSEvents 自動更新を検証する。active project に `<filename>` を作成 → debounce + rebuild 待ち → `FileIndex.search(<filename>)` の hit 数を Logger に出す。その後ファイルを削除して、削除後の hit 数も同様に出す。1 サイクル ~15 秒 |

例:
```bash
# バイナリ直叩き
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 \
POLEPOLE_TEST_AUTO_PREVIEW="REQUIREMENTS.md" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev"

# open -n 経由でも --env を並べれば渡せる（Debug ビルドはプロセス名 "PolePole Dev"）
open -n "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app" \
  --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=1 --env POLEPOLE_TEST_UNREAD_INDICES=0,2
```

### Dev ビルドのライセンスと POLEPOLE_BACKEND_URL

- Debug ビルドのライセンス API はデフォルトで `http://127.0.0.1:8787`（ローカル wrangler dev）を向く（`LicenseClient.defaultBaseURL()`）。ローカル backend が起動していないと、アクティベートは「ネットワークエラー」、既存 token の再検証は失敗し続けて**オフライン猶予（30日）切れでトライアル/購入モーダルが復活する**
- このため `scripts/polepole-launch.sh` と `mise run run` は `POLEPOLE_BACKEND_URL=https://polepole.dev` をデフォルトで渡す。ライセンスフローをローカル backend で検証するときだけ `POLEPOLE_BACKEND_URL=http://127.0.0.1:8787 ./scripts/polepole-launch.sh` のように明示上書きする
- Dev のライセンス保存先は実 Keychain ではなく `~/Library/Application Support/polepole-dev/keychain-debug.json`（`#if DEBUG` の DebugStore）。Brew 版と完全分離されており、トライアル切れ画面を再検証したいときはこのファイルの `activation-token` を消せば戻せる（`trial.json` を消すとトライアル自体が最初から）
- 自分用の無料クーポン（コードは非公開）は **Stripe Checkout の 100% OFF クーポン**であってライセンスキーではない。開発者自身のキーはこのクーポンで発行済み（本番 D1 の `license` テーブルに active で登録済み）
- **grace 切れで「ライセンスが無効化されました」にロックされたら CLI で再アクティベートできる**（2026-08-06 に発生・復旧済み。ロック後は `verifyIfNeeded()` が `state == .activated` 前提のため本番 API に繋がっても自己回復しない = 仕様）。手順: ① 旧 token（`token.json` の `.` 区切り前半を base64url decode）から `key` / `device_hash` を取り出す → ② `curl -X POST https://polepole.dev/v1/license/activate -H "Content-Type: application/json" -d '{"key":"...","email":"...","device_hash":"...","device_name":"dev-reactivate","os_version":"...","app_version":"dev"}'` → ③ レスポンスの `token` を `token.json`（`{"token":"..."}`）と `keychain-debug.json` の `activation-token` の両方に書いて再起動。同一 `device_hash` なら `created: false` でデバイススロットは消費されない

---

## ログの見方

| ログファイル | 用途 |
|---|---|
| `~/Library/Logs/{ide,polepole-dev}/{ide,polepole-dev}-YYYY-MM-DD.log` | 永続ログ。日次ローテーション、7 日 / 50MB 超で削除。stderr にも出力 |
| `/tmp/polepole-poc.log` | **Debug ビルドのみ** の Logger ミラー。`init()` で `Logger.shared.resetDebugMirror()`、以後 `Logger.shared.{debug,info,...}` の出力が追記される。`tail -f` で追える |

ログ経路は `Logger` に一本化済み（旧 `PocLog` は撤去）。`Logger.shared.debug(...)` で書き、Debug なら `/tmp/polepole-poc.log` にも、Release なら永続ログ + stderr のみ。

---

## Swift 6 strict concurrency の落とし穴

過去に踏んだもののまとめ:

- **NSView 配下で C ポインタを `deinit` から触る**: `nonisolated(unsafe) private var ptr: SomePointerType?` が必要
- **`Timer` プロパティを `deinit` から `invalidate()`**: `nonisolated(unsafe)` でラップ
- **AppKit プロトコル（NSTextInputClient 等）への準拠**: `extension X: @preconcurrency Protocol`
- **`Timer.scheduledTimer` の closure**: nonisolated なので `Task { @MainActor in ... }` でメインに戻す
- **`MainActor.assumeIsolated` を background queue から呼ぶとサイレントクラッシュ**: 値は MainActor 上で先に capture する
- **`@unchecked Sendable` で struct を fix**: ただし non-Sendable な stored property（`FileManager` 等）は computed property で逃がす
- **`WKScriptMessageHandler` は weak ref で渡す**: `userContentController.add(self, name:)` で controller 自身を渡すと WKWebView → handler → controller の強参照になり、controller が singleton でない場合リークする。`weak var owner` を持つ薄い nested class でラップして渡す（[PreviewWebView.swift](../Sources/polepole/PreviewWebView.swift) の `MessageHandler`）
- **`evaluateJavaScript` で JS から構造化結果を受け取る**: JS 側は常にオブジェクトを返す（`(window.viewer && window.viewer.find) ? window.viewer.find(q) : {count:0,index:0}`）。`undefined`/`null` を返すと async 版が throw することがある。Swift 側は completion-handler 版を `withCheckedContinuation` で包んで `async` メソッドにすると `@MainActor` クラスから素直に呼べる（[PreviewWebView.swift](../Sources/polepole/PreviewWebView.swift) の `evalFind` / find バー周り）。文字列を JS リテラルに埋めるときは `JSONEncoder().encode(s)`（JSON 文字列 ≒ JS 文字列）でエスケープする
- **WKWebView で file:// ページから別ディレクトリの file:// リソースを読む**: `loadFileURL(_:allowingReadAccessTo:)` の第2引数（許可ディレクトリ）配下しか読めない。バンドル内の `viewer.html` から見ると、Markdown 中の `![](./img.png)` のようなプロジェクト内画像は権限外で表示できない。WebView を使い回す構成では許可スコープを後から変えられないので、`WKURLSchemeHandler` を `config.setURLSchemeHandler(_:forURLScheme:)` で登録し、JS 側で `<img src>` を独自スキーム（`ideres://`）に書き換えて Swift がディスクから読んで返す（`allowedRoot` 配下チェックもそこで実施。`URLResponse` の MIME type は `UTType(filenameExtension:)?.preferredMIMEType`）。`WKWebViewConfiguration` は WebView 生成時にコピーされるが scheme handler の実体は共有されるので、ハンドラからシングルトン（`PreviewWebController.shared`）を参照すれば足りる。再描画時に WebKit のメモリキャッシュで古い画像が出ないよう、書き換え後の URL にクエリのキャッシュバスターを付けると確実（[PreviewWebView.swift](../Sources/polepole/PreviewWebView.swift) の `LocalResourceSchemeHandler` / [viewer.js](../Resources/preview/viewer.js) の `rewriteLocalImageSrcs`）

---

## SwiftUI まわりのクセ

- **3 カラム split は SwiftUI `HSplitView` ではなく `NSSplitViewController` を NSViewControllerRepresentable でラップする**: SwiftUI 側は `idealWidth` / `maxWidth` が「hint」程度にしか効かず、しかも `autosaveName`・`holdingPriority`・`setPosition`・delegate を一切露出しない。要件が「初期 2:3 + ドラッグ位置を永続化 + ウィンドウ拡縮で右ペインが優先的に伸びる」と複数ある時点で SwiftUI 側で完結する手はない。AppKit に降りて `NSSplitViewItem.holdingPriority` で拡縮分配・`splitView.autosaveName` で永続化・`setPosition(_:ofDividerAt:)` で初期位置を握る（[RootLayoutView.swift](../Sources/polepole/RootLayoutView.swift) の `ThreeColumnSplit`）
- **NSSplitView の「初期 layout を一度だけ確定する」設計は SwiftUI 配下で壊れる**: `viewDidLayout` は起動中に何度も呼ばれ、最初の数回はウィンドウ復元前の中間サイズ（`minWidth` 相当）で来る。`didSetInitial` フラグで 1 回ロックすると、その時点の小さい幅で比率が固定 → ウィンドウが本来サイズに復元されたあとも再計算されず、**右ペインが余剰を全部吸って中央が極端に狭く（or 広く）見える**。`userHasDragged == false` の間は viewDidLayout のたびに比率を再計算する設計が安定。ドラッグされたら以降は AppKit の autosave に任せる
- **NSSplitView のドラッグ検知に `splitViewDidResizeSubviews` の `NSSplitViewDividerIndex` userInfo を使ってはいけない**: Apple のドキュメント上は「ユーザがドラッグした時に入る」と読めるが、実際は AppKit が**初期 layout を確定するときにも同じ userInfo を入れる**。これでドラッグ判定すると起動直後に true になり、初期比率の再計算ロジックが死ぬ。確実に検知するには `NSSplitView` を subclass して `mouseDown(with:)` を override し、divider 矩形（`arrangedSubviews[i].frame.maxX` から `dividerThickness` 分の帯）に入っていれば「ユーザ操作」と判定する（[RootLayoutView.swift](../Sources/polepole/RootLayoutView.swift) の `DragDetectingSplitView`）
- **NSSplitView の autosave 有無は `autosaveName` をセットする「前」に確認する**: AppKit は `splitView.autosaveName = ...` を代入した瞬間に `UserDefaults` の `NSSplitView Subview Frames <name>` キーを読みに行く。「保存値があれば AppKit に任せ、無ければ初期比率を適用する」分岐をしたいなら、autosaveName をセットする前に `UserDefaults.standard.object(forKey:)` で存在チェックする
- **autosave データがおかしくなった疑いがある時のリセット**: `defaults delete local.d0ne1s.polepole "NSSplitView Subview Frames ide.rootSplit"`（Debug ビルドは `local.d0ne1s.polepole.dev`）。再起動で初期 2:3 から始まる
- **再帰的な `@ViewBuilder`**: opaque type 推論が壊れるので、データ側で flatten するか `AnyView` に逃がす（[FileTreeView.swift](../Sources/polepole/FileTreeView.swift) の `flattenedNodes()`）
- **`.background(Subview)` 内の `@ObservedObject`** は外側 body の再描画に伝播しない: 監視したい型は `body` を持つ View 自身に `@ObservedObject` で持たせる
- **深くネストした `@Published` は親の `@ObservedObject` まで伝播しない**: `ProjectsModel`→`WorkspaceModel`→`PaneState`→`TerminalTab.@Published` の葉を変えても、`ProjectsModel` だけ `@ObservedObject` する View は再描画されない。監視対象の型に派生 `@Published`（`unreadProjectIDs` 等）を持ち、葉を変える全箇所から再計算メソッド（`refreshUnreadProjects()`）を呼ぶ。init で値を入れてから View 初描画なら通知不要だが、後から変わるなら必須
- **`.overlay` / `.background` でフレーム外に描いた分はクリップされうる**: `ScrollView` 等の中で `Circle().stroke(...).padding(-N)` のように外側へリングをはみ出させても見えないことがある。フレーム内に確実に描くなら `Circle().strokeBorder(...)`（縁を内側に引く）か、内側コンテンツを inset してリング用の余白を作る
- **AppleScript の `click at {x, y}`** は SwiftUI の `onTapGesture` に届かないことがある（カスタムタブバー等の `Button` も同様に反応しないことがある）: 動作確認は `POLEPOLE_TEST_*` 環境変数 or 座標連打で迂回、本格的な hit test は手動確認に倒す。入力を送る `osascript` は毎回 `set frontmost to true` から始める（osascript 終了でフォーカスが呼び出し元ターミナルに戻るので、複数呼び出しに分けると2発目以降が PolePole に届かない）。`keystroke "..."` の直後に `key code 36`（Enter）を続けると Ghostty 端末で Enter が落ちることがある → Enter は別 osascript で、効かなければ2回送る
- **`URL` の `==` は scheme/baseURL の差で一致しないことがある**: 比較は `URL.standardizedFileURL.path`（String）で行う
- **NSView の自動 `becomeFirstResponder` 時は `NSApp.currentEvent` が nil**: 起動時に SplitView が NSHostingController を組み立てる過程で、最初に追加された NSView が自動で firstResponder になる。`WorkspaceModel.init` で設定した初期 `activePane = bottomPane` を上書きされたくない場合は、`becomeFirstResponder` 内で `NSApp.currentEvent?.type` が `.leftMouseDown` / `.keyDown` 等のユーザー操作起因のときだけ `setActive` を呼ぶ（[GhosttyTerminalView.swift](../Sources/polepole/GhosttyTerminalView.swift) の `isUserDrivenFirstResponderChange()`）
- **SwiftUI `@FocusState` は AppKit の firstResponder 移動を検知しない**: `.focused($state)` を当てた SwiftUI ビューにフォーカスがある状態で Ghostty 端末（NSView）が `becomeFirstResponder` を取っても `state` は `true` のまま残る。フォーカスを gate 条件にする挙動（例: ツリーにフォーカス時だけ Cmd+R で再スキャン、`MRUKeyMonitor` 側で `ProjectsModel.fileTreeFocused` を見る）を作るときは、(1) `@FocusState` を `@Published` にミラー、(2) フォーカスを奪う側の NSView の `becomeFirstResponder()` でその `@Published` を明示的に `false` にする、(3) `.focusable()` は click だけだとフォーカスを取らないことがあるので `.onTapGesture` 内で `@FocusState` を直接 `true` にする、の3点セットで整合させる。`.focusable()` のフォーカスリングが邪魔なら `.focusEffectDisabled()`（[FileTreeView.swift](../Sources/polepole/FileTreeView.swift) / [GhosttyTerminalView.swift](../Sources/polepole/GhosttyTerminalView.swift)）
- **SourceKit の `Cannot find type ...` 警告は基本無視**: xcodegen 構成では SourceKit が project.yml を読まずファイル単独で解析するため `PaneState` 等が見つからない警告を多数吐く。`mise run build` が `BUILD SUCCEEDED` なら実害なし

---

## 上下 divider にホバーしても resize cursor が出ない（未解決）

WorkspaceView の上下分割 (`WideHandleSplitView`) で、divider にホバーしても
`resizeUpDown` カーソルにならない。**ドラッグでの領域変更自体は可能**で、不具合はあくまで
「ホバー時のカーソル形状」だけ。2026-05-28 に複数アプローチを試したが解決できず、
`dividerThickness` を 11px に広げて drag を掴みやすくする改善だけ入れて撤退した。

### なぜ難しいか（根本原因）

1. **AppKit の cursor 解決は hitTest ベース**: マウス移動のたびに window が hitTest で
   最前面 view を探し、その view の `cursorUpdate(_:)` / cursor rect を使う。
2. **portal host (`TerminalsHostView`) が ZStack 最上層**: WorkspaceView は
   `ZStack { SplitPane; TerminalsHostRepresentable }` で、host が divider 領域も視覚的に覆う
   (host bounds = ZStack 全体)。host は terminal subview の frame 外では hitTest が nil を返す。
3. **divider 領域は terminal subview の frame 外**: なので divider 上では host hitTest が nil →
   AppKit は cursor 解決を下層 NSSplitView に回す。
4. **だが NSSplitView も divider cursor を出さない**: `dividerStyle = .thin` / `.thick` は
   AppKit が divider に cursor rect を一切登録しない。`.paneSplitter` にしても host が前面にいる
   構造のせいか効かなかった。

整理すると「host が前面 → host は divider 領域で hit を持たない → 下層 NSSplitView に回る →
NSSplitView も cursor を出さない」の二段構えで、どの層も divider cursor を担当しない状態。

### 試した手法と失敗理由（すべて未達）

| 手法 | 結果 / 失敗理由 |
|---|---|
| `splitView(_:effectiveRect:forDrawnRect:ofDividerAt:)` で hot region を上下に拡張 | **drag は掴みやすくなった**が cursor は不変。effective rect は drag 判定にしか使われない |
| `NSSplitView` subclass の `resetCursorRects()` で `addCursorRect(.resizeUpDown)` 明示登録 | 無効。`addCursorRect` は「その view が前面に覆われている領域では無効化」される AppKit 仕様で、ZStack 最上層の host が divider 領域を覆っているため潰される |
| host 自身の `resetCursorRects()` でも同じ位置に `addCursorRect` | 無効（同上、aggregation で安定しない） |
| host に `NSTrackingArea(.cursorUpdate)` を張り `cursorUpdate(with:)` で band 判定 → `NSCursor.resizeUpDown.set()` 強制 | **divider 本体では `cursorUpdate` が呼ばれない**。host hitTest が nil の領域では AppKit が host の cursorUpdate をスキップして下層に回すため。terminal frame 内 (divider のすぐ上) でだけ呼ばれて cursor が出るが、そこは hit が terminal に渡るので drag できずテキスト選択になる → 「少し上で cursor 出るのに drag できない」違和感の元 |
| 上記 band を `dividerThickness` 起点に splitView から query (host の `observedSplitView`) | band 位置の計算自体は `sv.isFlipped=true` を考慮すれば正しくなった。が、結局上記「hitTest nil 領域で cursorUpdate が呼ばれない」制約に阻まれて divider 本体では出ない |
| `dividerThickness` を 11px に拡張 (divider を実体ハンドル化、レビュー提案) + `.paneSplitter` | native cursor を期待したが出ず。host が前面にいる構造が変わらない限り native cursor aggregation は効かない |

### 確定した制約

- **`addCursorRect` は前面 view に覆われた領域では無効**。ZStack で重ねる構成では下層の
  cursor rect は最前面 view に潰される。
- **`NSTrackingArea(.cursorUpdate)` の `cursorUpdate(with:)` は hitTest と連動する**。
  owner view が hitTest で nil を返す領域には飛んでこない (tracking area を張っていても)。
- **`NSSplitView` は `.thin` / `.thick` で divider cursor rect を登録しない**。
- **CGEvent.post でマウスを動かしても `NSCursor` 更新は再現しない**ので、cursor 形状の確認は
  必ず手動マウス操作 + `screencapture -C` でやる (このため検証が遅く、試行のたびにユーザーへ
  手動ホバーを依頼することになった)。

### 残した改善と今後の方針

- 残したもの: `WideHandleSplitView` で `dividerThickness = 11`、`drawDivider(in:)` で中央 1px
  だけ描画。**見た目は従来の細い線のまま、drag のヒット領域だけ 11px に広がる**。cursor は未解決。
- 長期的な本命案 (コードレビューでの提案): **full-window の単一 host をやめ「1 terminal =
  1 stable lease host」を window root に置く**。realNSView は lease host に固定し、lease host
  自体の frame だけ anchor に追従させる。こうすると host が画面全体を覆わなくなり、cursor
  aggregation の面積が terminal 実体分だけになるので、divider 領域は素の NSSplitView が
  担当できて native cursor が出る見込み。ただし libghostty の reparent 制約 ([Phase 3](./plans/2026-05-27-pane-layout-and-cross-pane-tabs.md)) と両立する設計が必要で工数大。
  「divider cursor がどうしても欲しい」という強いシグナルが来たら着手する。

---

## Ghostty のテーマ / リソースディレクトリ

- **libghostty には標準テーマ集が同梱されていない**: スタンドアロン Ghostty.app は `Contents/Resources/ghostty/themes/` にテーマファイルを持つが、`GhosttyKit.xcframework` には無い。そのままだと `~/.config/ghostty/config` の `theme = "GitHub Dark"` 等が解決できず**デフォルト配色（明るめのグレー）にフォールバック**して「もやがかかったような薄い色」に見える
- **対策**: `scripts/fetch-ghostty-themes.sh` で [mbadolato/iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) の `ghostty/` を `Resources/ghostty/themes/` に取得 → `project.yml` で folder reference として bundle → `GhosttyManager.configureResourcesDir()` が起動時（`ghostty_init` の前）に `GHOSTTY_RESOURCES_DIR` を `<bundle>/Contents/Resources/ghostty` に向ける（env に既にあれば尊重、無ければ `/Applications/Ghostty.app/...` にフォールバック）
- **確認**: 起動後 `grep -i ghostty /tmp/polepole-poc.log` で `GHOSTTY_RESOURCES_DIR -> ...` が出ていて、`theme "..." not found` の diagnostic が消えていれば OK
- テーマを更新したくなったら `./scripts/fetch-ghostty-themes.sh` を再実行（差分は git で確認）

### terminfo も同梱が必要

- **libghostty は子プロセスのシェルに必ず `TERM=xterm-ghostty` と `TERMINFO=<GHOSTTY_RESOURCES_DIR の隣>/terminfo`（= `<bundle>/Contents/Resources/terminfo`）をセットする**が、`GhosttyKit.xcframework` には terminfo 本体が同梱されていない（スタンドアロン Ghostty.app は `Contents/Resources/terminfo/` に持っている）。terminfo が引けないと `el` / `cuf1` / `hpa` 等が無く、**カーソル移動・行クリアのエスケープシーケンスが全滅して入力中の表示が崩れる**（`ls` と打つと `lssls` のように残骸が残る、`clear` が `'xterm-ghostty': unknown terminal type.` を出す）。以前は standalone Ghostty / `brew ghostty` がシステムに terminfo を入れてくれていたので顕在化しなかったが、それが無い環境では壊れる
- **対策**: `scripts/fetch-ghostty-terminfo.sh` が ghostty 本体の `src/terminfo/ghostty.zig`（`GhosttyKit.xcframework/.ghostty_sha` で pin）から terminfo source を起こして `tic -x` でコンパイル → `Resources/terminfo/`（`{67/ghostty, 78/xterm-ghostty}`）に出力 → `project.yml` の folder reference で bundle。`<bundle>/Contents/Resources/terminfo/` に置けば libghostty が自動でそこを `TERMINFO` に向ける（コード変更不要）
- **確認**: ビルド後 `find "<app>/Contents/Resources/terminfo" -type f` で2ファイル出る / アプリ内シェルで `infocmp xterm-ghostty` が成功し `clear` がエラーを出さず実際に画面がクリアされる。**※シェルは起動時に terminfo を読んでキャッシュするので、必ず新しいタブ（Cmd+T）で確認する** — terminfo 修正前に開いていたタブは壊れたまま見えるので「直ってない」と誤判定しやすい
- xcframework を更新したら（`.ghostty_sha` が変わったら）`./scripts/fetch-ghostty-terminfo.sh` を再実行（差分は git で確認）

### libghostty の設定マージ（bundled config + user config）

`GhosttyManager.start()` は bundled `Resources/ghostty/config` を `ghostty_config_load_file` で先にロードしてから `ghostty_config_load_default_files` でユーザー設定を読む。後勝ちなので **多くのキーはユーザー設定が override する** が、list 型のキーには罠がある。

- **`font-family` は `RepeatableString`（append される）**: 複数回書くと list に追加される。bundled で書いた値が user の値より **前** に残るため、bundled が優先順位で勝ってしまう（Ghostty は list 先頭から glyph を探すので、bundled の "JetBrains Mono" が user の "SF Mono" を押しのける）。user 設定を真に優先したいなら、bundled の load 後・user の load 前に `ghostty_config_load_string(cfg, "font-family = \"\"", ...)` で list を reset する必要がある。`GhosttyManager.userConfigSpecifiesFontFamily()` がそのための判定。`font-family-bold` / `font-family-italic` / `font-family-bold-italic` も同様の `RepeatableString`
- **`theme` は単一値（`?Theme = null`）なので普通に last-wins**: 単一値フィールドは load 順だけで決まる。bundled に書いた theme は user の theme で素直に上書きされる
- **設定キーの型を調べる**: Ghostty 本家 `src/config/Config.zig` のフィールド定義を見れば `RepeatableString` か `?T = null` か `T = default` か分かる。`curl -sL https://raw.githubusercontent.com/ghostty-org/ghostty/main/src/config/Config.zig` で取れる
- **config の load API は 5 つ**: `ghostty_config_load_file(cfg, path)` / `_string(cfg, str, len, source)` / `_default_files(cfg)` / `_recursive_files(cfg)` / `_cli_args(cfg)`。load 順序は呼び出し順そのまま。ヘッダは `GhosttyKit.xcframework/macos-arm64_x86_64/Headers/ghostty.h:1083-1087`
- **確認**: `grep "ghostty" /tmp/polepole-poc.log` で `loaded bundled config: ...` の行が出る。user 設定で font-family を override しているケースは `user config has font-family; reset bundled font-family list` も追加で出る。`config diagnostics: 0` なら parse error なし

---

## キー入力の優先順位

詳細は [ARCHITECTURE.md](./ARCHITECTURE.md#キー入力の優先順位)。

要点だけ:
- **NSEvent.addLocalMonitorForEvents（MRUKeyMonitor）が最優先**。Ctrl+M / Cmd+P / Cmd+Shift+F / (ツリーにフォーカス時) Cmd+R は vim/claude の中でも握る
- `Ctrl+M` は `keyCode == 46` で判定（macOS が Ctrl+letter を CR にマップする問題回避）
- 検索バー / オーバーレイ表示中に Return / Esc / ↑↓ を横取りする箇所は、**IME 変換中（field editor が marked text を持つ）なら横取りせずイベントを素通り**させる。さもないと日本語変換の確定（Return）・キャンセル（Esc）・候補移動（↑↓）が IME に届かない。判定は `NSApp.keyWindow?.firstResponder as? NSTextInputClient` → `hasMarkedText()`（`MRUKeyMonitor.isComposingInTextField()`）

---

## ドキュメント構成

```
ide/
├─ README.md             プロジェクト全体の入口
├─ REQUIREMENTS.md       要件
├─ VERIFY.md             動作確認手順（自動・手動）
├─ CLAUDE.md             AI（Claude Code）向けガイド
└─ docs/
   ├─ ARCHITECTURE.md    モジュール構成・データフロー
   ├─ BACKLOG.md         残タスク・将来アイデア（優先度別）
   ├─ DEV.md             ← この文書
   └─ plans/
      ├─ phase1-terminal.md
      └─ phase2-files.md
```

---

## ディレクトリ構成

```
Sources/polepole/
├─ PolePoleApp.swift / ContentView.swift / RootLayoutView.swift / CenterPaneView.swift  アプリ全体
├─ Project.swift / ProjectsModel.swift / ProjectsStore.swift  プロジェクト管理
├─ ProjectColor.swift / ProjectAvatarView.swift / ProjectEditSheet.swift  アバター・色・編集シート
├─ LeftSidebarView.swift  左サイドバー（D&D 並び替え + 下部「+」ボタン）
├─ WorkspaceView.swift / WorkspaceModel.swift / PaneState.swift / TerminalTab.swift / TabsView.swift  ターミナル
├─ GhosttyManager.swift / GhosttyTerminalView.swift / +Mouse / +TextInput  Ghostty ラッパ
├─ ExitedOverlayView.swift / ForegroundProcessInspector.swift  shell 終了 / AI 種別検知
├─ ClipboardSupport.swift  クリップボード（画像 → 一時ファイル）
├─ FileTreeModel.swift / FileNode.swift / FileTreeView.swift  ファイルツリー
├─ GitIgnoreChecker.swift / GitStatusModel.swift  git 連携
├─ FilePreviewModel.swift / FilePreviewView.swift / PreviewWebView.swift  プレビュー（WKWebView + highlight.js）
├─ FileIndex.swift / QuickSearchView.swift  Cmd+P
├─ FullTextSearcher.swift / FullSearchView.swift  Cmd+Shift+F
├─ MRUKeyMonitor.swift / MRUOverlayState.swift / MRUOverlayView.swift  Ctrl+M
├─ Logger.swift / Logging.swift  ログ
└─ ErrorBus.swift  toast
```
