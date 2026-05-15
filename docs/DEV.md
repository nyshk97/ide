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
| 起動（kill + open） | `./scripts/ide-launch.sh` |
| ビルド + 起動 | `mise run run` |
| `xcodeproj` 再生成のみ | `mise run regen` |
| クリーン | `mise run clean`（DerivedData + ide.xcodeproj を消す） |

`mise run build` は内部で `regen` を依存に持つので、新規 `.swift` ファイルを追加した直後でも忘れずに pickup される。

ビルド成果物は `/tmp/ide-build/Build/Products/Debug/ide.app`。

---

## リリース

1. `project.yml` の `MARKETING_VERSION` を bump → コミット（`fix:` 系とは別に `chore: バージョンを X に bump`）。`CURRENT_PROJECT_VERSION` は `$(MARKETING_VERSION)` で連動するので bump 不要
2. `scripts/release.sh <version>` — Release ビルド（Developer ID 署名 + notarize + staple）→ `git push origin main` → **2 つの repo に release を作成**:
   - `nyshk97/ide` — 既存どおり zip を asset として上げる（homebrew cask の URL 互換）
   - `nyshk97/ide-releases` — Sparkle 配信用。zip + `appcast.xml` を上げる
3. release.sh が `sign_update` で zip を **EdDSA 署名** し、過去の `appcast.xml` を取得 → 新 `<item>` を `</channel>` 直前に挿入してアップロードする（累積）
4. notarize / codesign の timestamp や `gh release upload` がネットワークを使うので **Bash サンドボックスを無効化して**走らせる（下の「`scripts/build.sh` はネットワークが要る」参照）
5. release.sh が末尾に出す `version` / `sha256` で homebrew-tap の cask を更新する: `"$(brew --repository)/Library/Taps/nyshk97/homebrew-tap/Casks/ide.rb"`（このローカル clone がそのまま作業ツリー。origin = `github.com/nyshk97/homebrew-tap`）の `version` と `sha256` を書き換えて commit & push
6. ローカルに最新版を入れる → **`scripts/install.sh`**（`/Applications/IDE.app` をバンドルごと差し替え。`build/ide.zip` が無ければ build から走る）

**dogfooding 中（IDE.app の中で Claude Code を回している）に `brew upgrade --cask ide` を打つと、cask が実行中の IDE.app を quit してそのセッションごと死ぬ**。`scripts/install.sh` はバンドルを上書きするだけで実行中プロセスは生かしたまま（macOS は使用中の .app バンドルを unlink してもプロセスは動き続ける）なので、こちらを使う。どちらにしても修正の反映には IDE.app の手動再起動が必要。`install.sh` 経由だと `brew` 側のバージョン表示はズレるが実害なし（次に `brew upgrade --cask ide` を打てば揃う）。

### Sparkle 自前アップデート

メニュー > `IDE` > `Check for Updates…` から手動で更新できる（要件「起動時に通信しない」を満たすため自動チェックは無効。`SUEnableAutomaticChecks=false`）。

- **配信フィード URL**: `https://github.com/nyshk97/ide-releases/releases/latest/download/appcast.xml`
- **配信 zip URL**: `https://github.com/nyshk97/ide-releases/releases/download/v<version>/ide.zip`
- 配信用 repo（`nyshk97/ide-releases`）は **public** 必須。Sparkle は匿名で curl する。本体 repo（`nyshk97/ide`）は将来 private 化しても更新フィードは動く

### EdDSA 鍵

### Sparkle は `CFBundleVersion` で比較する（MARKETING_VERSION と連動させる）

Sparkle の version 比較は appcast の `sparkle:version` と app の `CFBundleVersion` で行う（`shortVersionString` は表示用）。`CFBundleVersion` (= `CURRENT_PROJECT_VERSION`) を bump しないと、新版 zip を配っても「現バージョンと同じ」と判定されたり、逆に **app が自分自身を新版として offer** する（1.0.10 リリース後に CFBundleVersion=1 のままだと「build 1 のユーザーに 1.0.10 を案内」が初回 Check で発火する）。

そのため `project.yml` は `CURRENT_PROJECT_VERSION: "$(MARKETING_VERSION)"` で連動させてある。bump 時は `MARKETING_VERSION` だけ書き換えれば足りる。`release.sh` は built `.app/Contents/Info.plist` から `CFBundleVersion` / `CFBundleShortVersionString` を直接読んで appcast に書く（sanity check 付き）。

### `build.sh` の zip 化と `install.sh` の展開は `ditto` を使う（`zip` / `unzip` ではない）

`Sparkle.framework` は **シンボリックリンクで構成された framework バンドル**（`Resources -> Versions/Current/Resources` など）。`zip -r` のデフォルトは symlink を辿って実体ファイルに展開してしまい、framework 構造を壊す（codesign が "bundle format is ambiguous (could be app or framework)" を返し、Gatekeeper は「壊れているため開けません。ゴミ箱に入れる必要があります」を出す）。

そのため:
- ビルド側: `ditto -c -k --sequesterRsrc --keepParent IDE.app ide.zip`
- インストール側: `ditto -x -k ide.zip <dest>`

を使う。**Sparkle が embed されていなかった旧バージョン (1.0.9 以前) は plain zip でも動いていたが、Sparkle.framework が入った 1.0.10 から罠が顕在化**。同じ理由で `release.sh` 内の pubDate は `LC_ALL=C date` で英語に固定する（`LANG=ja_JP` だと「木, 14 5月 2026」になり Sparkle が parse 失敗する）。

### EdDSA 鍵

- 公開鍵は `Resources/Info.plist` の `SUPublicEDKey` に Base64 で埋まっている: `VnvTM72yjjc1FY/nzLI5uT/3mSxkOdG7k4dJqAPgZo8=`
- ペアの秘密鍵は **macOS Keychain** に保存されている（`sign_update` が暗黙的に参照する）
- 安全のため `~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-private.key`（`chmod 600`）にバックアップ
- **秘密鍵を失うと、旧バージョンに配ったユーザーの自動アップデートが恒久的に壊れる**（新鍵で署名し直した zip は受理されない）。新鍵を作ってリリースしても、ユーザー側は手動で新版 IDE.app を入れ直すまで詰む。Dropbox バックアップは消さないこと

### Sparkle のツール（generate_keys / sign_update）

SwiftPM が落としてくる artifact 内に同梱されている（`homebrew-cask` の `sparkle` は deprecated 且つ Test App しか入れないので使わない）:

```
/tmp/ide-build-release/SourcePackages/artifacts/sparkle/Sparkle/bin/
├── generate_keys     # 鍵ペア生成（一度だけ。Keychain 登録）
├── sign_update       # zip を EdDSA 署名（release.sh が自動で叩く）
└── BinaryDelta       # 差分更新の生成（今は使わない）
```

`build.sh` が `-derivedDataPath /tmp/ide-build-release` を固定しているので、`release.sh` からはこの絶対パスで `sign_update` を直接呼べる。`mise run build` の DerivedData は `/tmp/ide-build` で別なので注意（こっちで `generate_keys` を叩く分には問題ない）。

---

## 動作確認スクリプト

| スクリプト | 用途 |
|---|---|
| `scripts/ide-launch.sh [wait_seconds]` | ide を kill してから起動。デフォルト 3 秒待機 |
| `scripts/ide-keystroke.sh [--enter|--keycode N] "text"` | osascript（補助アクセス権限が必要）でキー送信 |
| `scripts/ide-screenshot.sh <path>` | `CGWindowList` でウィンドウ ID を引いて `screencapture -l` でキャプチャ（取れなければメイン画面全体にフォールバック） |

### TCC（プライバシー）権限の罠

「IDE の中で IDE を開発する」（IDE 内ターミナルで Claude Code を動かす）には、`/Applications/IDE.app` に下記 2 つの TCC 許可が必須。Release ビルドは安定した Developer ID 署名（固定 team `VYDUR99LAM` / bundle ID `local.d0ne1s.ide` / `CODE_SIGN_STYLE: Manual`）なので、一度付与すれば **brew 更新を跨いで残る**。macOS アップデート等で剥がれたら再付与（→ いずれも `IDE.app` を Cmd+Q & 再起動。TCC は起動時に読まれる）。

- **画面収録（`screencapture` / `ide-screenshot.sh`）が要るもの**:
  `screencapture` の TCC「責任プロセス」は、起動したプロセスのツリーを遡って最初の非システムバイナリに解決される。**IDE 内で Claude Code を動かしている場合は `IDE.app` 自身**（`login` でも `claude.exe` でもない。プロンプトも「"IDE.app" でこのコンピュータの画面を記録しようとしています」と出る）。なので **System Settings → プライバシーとセキュリティ → 画面収録 に `/Applications/IDE.app` を追加して ON**。剥がれたらリストから `IDE.app` を削除 → `screencapture`（or `ide-screenshot.sh`）を再実行 → 出た再プロンプトの「システム設定を開く」→ 新規追加された `IDE.app` を ON → IDE.app 再起動。
  - `ide-screenshot.sh` は `osascript` を捨てて `CGWindowList`（補助アクセス不要）+ `screencapture -l` にしてあるので「アクセシビリティ」は不要、「画面収録」だけでよい。
  - Claude Code を **IDE の外**（素の Terminal.app 等）から動かしている場合は責任プロセスがその端末アプリ（or `claude.exe`）になるので、そっちに画面収録を付与する必要がある。`claude.exe`（`com.anthropic.claude-code`）は CUI でプロンプトを出せないため、その経路だと「could not create image from display」と無言で失敗する。
- **フルディスクアクセス（`~/.zshrc` 等の dotfiles 読み込み）が要るもの**:
  dotfiles は実体が `~/Library/CloudStorage/Dropbox/dotfiles/` にあり symlink で配置されている（`~/.claude/CLAUDE.md` 参照）。`~/Library/CloudStorage/` 配下は TCC 保護なので、**`IDE.app` にフルディスクアクセスが無いと IDE 内ターミナルのログインシェルが `~/.zshrc` を辿れず `EPERM`（`source: operation not permitted`）で無言スキップ** → デフォルトプロンプト・mise 未起動・`claude` not found になる（subprocess は `IDE.app` の責任プロセス属性を継ぐので Claude Code も巻き込まれる）。**System Settings → プライバシーとセキュリティ → フルディスクアクセス に `/Applications/IDE.app` を追加して ON**（→ IDE.app 再起動）すれば直る。IDE 内 Claude Code が `~/Library/CloudStorage/Dropbox/` の `Brewfile` / `dotfiles/` / `settings/` を読むのにも必要。
- **アクセシビリティ（`osascript` / `ide-keystroke.sh`）は IDE 内では諦める**:
  合成キー入力には `osascript` の補助アクセスが要るが、IDE 内ターミナルは `/usr/bin/login` 経由でシェルを起動するため TCC 責任プロセスが `IDE.app` に解決されず（ここだけ `login` が効く）、`osascript` 自体に毎回ポップアップが出る（恒久付与できない）。スクショ自体は `ide-screenshot.sh` が `osascript` を使わないので影響しないが、`ide-keystroke.sh`（キーストローク送信）が要る検証だけは Terminal.app / iTerm から `claude` を起動して回す（普通に署名された安定アプリ & `login` 介在なしで付与が効き続ける）。

- **`scripts/build.sh`（Release ビルド）はネットワークが要る**: codesign の `--timestamp`（`timestamp.apple.com`）や `xcrun notarytool`（Apple）が、Claude Code の Bash サンドボックスだと不達で落ちる（`A timestamp was expected but was not found` 等）。エージェントから走らせるときは Bash ツールのサンドボックスを無効化する。これ自体は人間検証向け。

詳しい確認手順は [VERIFY.md](../VERIFY.md)。

---

## テスト用環境変数

VERIFY 用に起動時の状態を仕込めるフラグ。**本番ユーザーは設定しない**前提。
すべて `~/Library/Application Support/ide-dev/projects.json` にピン留めが事前に書かれていることを前提にする。

| 環境変数 | 効果 |
|---|---|
| `IDE_TEST_AUTO_ACTIVATE_INDEX=N` | 起動時に N 番目のピン留めをアクティブ化（要件「再起動時は active を復元しない」を VERIFY で迂回するため） |
| `IDE_TEST_AUTO_PREVIEW=<rel-path>` | active project からの相対パスでプレビューを開く |
| `IDE_TEST_AUTO_FULLSEARCH=<query>` | 起動時に Cmd+Shift+F の overlay を開いて grep を実行（TextField.onSubmit が AppleScript の Enter で発火しないため） |
| `IDE_TEST_PREVIEW_FIND=<query>` | `IDE_TEST_AUTO_PREVIEW` でプレビューを開いた状態で Cmd+F のファイル内検索バーを開き、`<query>` をハイライトする |
| `IDE_TEST_TOAST=<message>` | 起動時に赤 toast を出す |
| `IDE_TEST_UNREAD_INDICES=0,2` | 起動時に N 番目（allOrdered = pinned + temporary）のプロジェクトの workspace を作り、下ペインのカレントタブに未読通知を立てる（サイドバーのリング表示の検証用）。`IDE_TEST_AUTO_ACTIVATE_INDEX` と同じインデックスを指すと「アクティブ化でその表示タブの未読が消える」挙動も確認できる |
| `IDE_TEST_AUTO_OPEN_DIFF=1` | 起動時に active project の diff overlay (Cmd+D) を自動で開く。`git diff` の取得は非同期なので screenshot 前に sleep を入れる |

例:
```bash
# バイナリ直叩き
IDE_TEST_AUTO_ACTIVATE_INDEX=0 \
IDE_TEST_AUTO_PREVIEW="REQUIREMENTS.md" \
  "/tmp/ide-build/Build/Products/Debug/IDE Dev.app/Contents/MacOS/IDE Dev"

# open -n 経由でも --env を並べれば渡せる（Debug ビルドはプロセス名 "IDE Dev"）
open -n "/tmp/ide-build/Build/Products/Debug/IDE Dev.app" \
  --env IDE_TEST_AUTO_ACTIVATE_INDEX=1 --env IDE_TEST_UNREAD_INDICES=0,2
```

---

## ログの見方

| ログファイル | 用途 |
|---|---|
| `~/Library/Logs/{ide,ide-dev}/{ide,ide-dev}-YYYY-MM-DD.log` | 永続ログ。日次ローテーション、7 日 / 50MB 超で削除。stderr にも出力 |
| `/tmp/ide-poc.log` | **Debug ビルドのみ** の Logger ミラー。`init()` で `Logger.shared.resetDebugMirror()`、以後 `Logger.shared.{debug,info,...}` の出力が追記される。`tail -f` で追える |

ログ経路は `Logger` に一本化済み（旧 `PocLog` は撤去）。`Logger.shared.debug(...)` で書き、Debug なら `/tmp/ide-poc.log` にも、Release なら永続ログ + stderr のみ。

---

## Swift 6 strict concurrency の落とし穴

過去に踏んだもののまとめ:

- **NSView 配下で C ポインタを `deinit` から触る**: `nonisolated(unsafe) private var ptr: SomePointerType?` が必要
- **`Timer` プロパティを `deinit` から `invalidate()`**: `nonisolated(unsafe)` でラップ
- **AppKit プロトコル（NSTextInputClient 等）への準拠**: `extension X: @preconcurrency Protocol`
- **`Timer.scheduledTimer` の closure**: nonisolated なので `Task { @MainActor in ... }` でメインに戻す
- **`MainActor.assumeIsolated` を background queue から呼ぶとサイレントクラッシュ**: 値は MainActor 上で先に capture する
- **`@unchecked Sendable` で struct を fix**: ただし non-Sendable な stored property（`FileManager` 等）は computed property で逃がす
- **`WKScriptMessageHandler` は weak ref で渡す**: `userContentController.add(self, name:)` で controller 自身を渡すと WKWebView → handler → controller の強参照になり、controller が singleton でない場合リークする。`weak var owner` を持つ薄い nested class でラップして渡す（[PreviewWebView.swift](../Sources/ide/PreviewWebView.swift) の `MessageHandler`）
- **`evaluateJavaScript` で JS から構造化結果を受け取る**: JS 側は常にオブジェクトを返す（`(window.viewer && window.viewer.find) ? window.viewer.find(q) : {count:0,index:0}`）。`undefined`/`null` を返すと async 版が throw することがある。Swift 側は completion-handler 版を `withCheckedContinuation` で包んで `async` メソッドにすると `@MainActor` クラスから素直に呼べる（[PreviewWebView.swift](../Sources/ide/PreviewWebView.swift) の `evalFind` / find バー周り）。文字列を JS リテラルに埋めるときは `JSONEncoder().encode(s)`（JSON 文字列 ≒ JS 文字列）でエスケープする
- **WKWebView で file:// ページから別ディレクトリの file:// リソースを読む**: `loadFileURL(_:allowingReadAccessTo:)` の第2引数（許可ディレクトリ）配下しか読めない。バンドル内の `viewer.html` から見ると、Markdown 中の `![](./img.png)` のようなプロジェクト内画像は権限外で表示できない。WebView を使い回す構成では許可スコープを後から変えられないので、`WKURLSchemeHandler` を `config.setURLSchemeHandler(_:forURLScheme:)` で登録し、JS 側で `<img src>` を独自スキーム（`ideres://`）に書き換えて Swift がディスクから読んで返す（`allowedRoot` 配下チェックもそこで実施。`URLResponse` の MIME type は `UTType(filenameExtension:)?.preferredMIMEType`）。`WKWebViewConfiguration` は WebView 生成時にコピーされるが scheme handler の実体は共有されるので、ハンドラからシングルトン（`PreviewWebController.shared`）を参照すれば足りる。再描画時に WebKit のメモリキャッシュで古い画像が出ないよう、書き換え後の URL にクエリのキャッシュバスターを付けると確実（[PreviewWebView.swift](../Sources/ide/PreviewWebView.swift) の `LocalResourceSchemeHandler` / [viewer.js](../Resources/preview/viewer.js) の `rewriteLocalImageSrcs`）

---

## SwiftUI まわりのクセ

- **3 カラム split は SwiftUI `HSplitView` ではなく `NSSplitViewController` を NSViewControllerRepresentable でラップする**: SwiftUI 側は `idealWidth` / `maxWidth` が「hint」程度にしか効かず、しかも `autosaveName`・`holdingPriority`・`setPosition`・delegate を一切露出しない。要件が「初期 2:3 + ドラッグ位置を永続化 + ウィンドウ拡縮で右ペインが優先的に伸びる」と複数ある時点で SwiftUI 側で完結する手はない。AppKit に降りて `NSSplitViewItem.holdingPriority` で拡縮分配・`splitView.autosaveName` で永続化・`setPosition(_:ofDividerAt:)` で初期位置を握る（[RootLayoutView.swift](../Sources/ide/RootLayoutView.swift) の `ThreeColumnSplit`）
- **NSSplitView の「初期 layout を一度だけ確定する」設計は SwiftUI 配下で壊れる**: `viewDidLayout` は起動中に何度も呼ばれ、最初の数回はウィンドウ復元前の中間サイズ（`minWidth` 相当）で来る。`didSetInitial` フラグで 1 回ロックすると、その時点の小さい幅で比率が固定 → ウィンドウが本来サイズに復元されたあとも再計算されず、**右ペインが余剰を全部吸って中央が極端に狭く（or 広く）見える**。`userHasDragged == false` の間は viewDidLayout のたびに比率を再計算する設計が安定。ドラッグされたら以降は AppKit の autosave に任せる
- **NSSplitView のドラッグ検知に `splitViewDidResizeSubviews` の `NSSplitViewDividerIndex` userInfo を使ってはいけない**: Apple のドキュメント上は「ユーザがドラッグした時に入る」と読めるが、実際は AppKit が**初期 layout を確定するときにも同じ userInfo を入れる**。これでドラッグ判定すると起動直後に true になり、初期比率の再計算ロジックが死ぬ。確実に検知するには `NSSplitView` を subclass して `mouseDown(with:)` を override し、divider 矩形（`arrangedSubviews[i].frame.maxX` から `dividerThickness` 分の帯）に入っていれば「ユーザ操作」と判定する（[RootLayoutView.swift](../Sources/ide/RootLayoutView.swift) の `DragDetectingSplitView`）
- **NSSplitView の autosave 有無は `autosaveName` をセットする「前」に確認する**: AppKit は `splitView.autosaveName = ...` を代入した瞬間に `UserDefaults` の `NSSplitView Subview Frames <name>` キーを読みに行く。「保存値があれば AppKit に任せ、無ければ初期比率を適用する」分岐をしたいなら、autosaveName をセットする前に `UserDefaults.standard.object(forKey:)` で存在チェックする
- **autosave データがおかしくなった疑いがある時のリセット**: `defaults delete local.d0ne1s.ide "NSSplitView Subview Frames ide.rootSplit"`（Debug ビルドは `local.d0ne1s.ide.dev`）。再起動で初期 2:3 から始まる
- **再帰的な `@ViewBuilder`**: opaque type 推論が壊れるので、データ側で flatten するか `AnyView` に逃がす（[FileTreeView.swift](../Sources/ide/FileTreeView.swift) の `flattenedNodes()`）
- **`.background(Subview)` 内の `@ObservedObject`** は外側 body の再描画に伝播しない: 監視したい型は `body` を持つ View 自身に `@ObservedObject` で持たせる
- **深くネストした `@Published` は親の `@ObservedObject` まで伝播しない**: `ProjectsModel`→`WorkspaceModel`→`PaneState`→`TerminalTab.@Published` の葉を変えても、`ProjectsModel` だけ `@ObservedObject` する View は再描画されない。監視対象の型に派生 `@Published`（`unreadProjectIDs` 等）を持ち、葉を変える全箇所から再計算メソッド（`refreshUnreadProjects()`）を呼ぶ。init で値を入れてから View 初描画なら通知不要だが、後から変わるなら必須
- **`.overlay` / `.background` でフレーム外に描いた分はクリップされうる**: `ScrollView` 等の中で `Circle().stroke(...).padding(-N)` のように外側へリングをはみ出させても見えないことがある。フレーム内に確実に描くなら `Circle().strokeBorder(...)`（縁を内側に引く）か、内側コンテンツを inset してリング用の余白を作る
- **AppleScript の `click at {x, y}`** は SwiftUI の `onTapGesture` に届かないことがある（カスタムタブバー等の `Button` も同様に反応しないことがある）: 動作確認は `IDE_TEST_*` 環境変数 or 座標連打で迂回、本格的な hit test は手動確認に倒す。入力を送る `osascript` は毎回 `set frontmost to true` から始める（osascript 終了でフォーカスが呼び出し元ターミナルに戻るので、複数呼び出しに分けると2発目以降が IDE に届かない）。`keystroke "..."` の直後に `key code 36`（Enter）を続けると Ghostty 端末で Enter が落ちることがある → Enter は別 osascript で、効かなければ2回送る
- **`URL` の `==` は scheme/baseURL の差で一致しないことがある**: 比較は `URL.standardizedFileURL.path`（String）で行う
- **NSView の自動 `becomeFirstResponder` 時は `NSApp.currentEvent` が nil**: 起動時に SplitView が NSHostingController を組み立てる過程で、最初に追加された NSView が自動で firstResponder になる。`WorkspaceModel.init` で設定した初期 `activePane = bottomPane` を上書きされたくない場合は、`becomeFirstResponder` 内で `NSApp.currentEvent?.type` が `.leftMouseDown` / `.keyDown` 等のユーザー操作起因のときだけ `setActive` を呼ぶ（[GhosttyTerminalView.swift](../Sources/ide/GhosttyTerminalView.swift) の `isUserDrivenFirstResponderChange()`）
- **SwiftUI `@FocusState` は AppKit の firstResponder 移動を検知しない**: `.focused($state)` を当てた SwiftUI ビューにフォーカスがある状態で Ghostty 端末（NSView）が `becomeFirstResponder` を取っても `state` は `true` のまま残る。フォーカスを gate 条件にする挙動（例: ツリーにフォーカス時だけ Cmd+R で再スキャン、`MRUKeyMonitor` 側で `ProjectsModel.fileTreeFocused` を見る）を作るときは、(1) `@FocusState` を `@Published` にミラー、(2) フォーカスを奪う側の NSView の `becomeFirstResponder()` でその `@Published` を明示的に `false` にする、(3) `.focusable()` は click だけだとフォーカスを取らないことがあるので `.onTapGesture` 内で `@FocusState` を直接 `true` にする、の3点セットで整合させる。`.focusable()` のフォーカスリングが邪魔なら `.focusEffectDisabled()`（[FileTreeView.swift](../Sources/ide/FileTreeView.swift) / [GhosttyTerminalView.swift](../Sources/ide/GhosttyTerminalView.swift)）
- **SourceKit の `Cannot find type ...` 警告は基本無視**: xcodegen 構成では SourceKit が project.yml を読まずファイル単独で解析するため `PaneState` 等が見つからない警告を多数吐く。`mise run build` が `BUILD SUCCEEDED` なら実害なし

---

## Ghostty のテーマ / リソースディレクトリ

- **libghostty には標準テーマ集が同梱されていない**: スタンドアロン Ghostty.app は `Contents/Resources/ghostty/themes/` にテーマファイルを持つが、`GhosttyKit.xcframework` には無い。そのままだと `~/.config/ghostty/config` の `theme = "GitHub Dark"` 等が解決できず**デフォルト配色（明るめのグレー）にフォールバック**して「もやがかかったような薄い色」に見える
- **対策**: `scripts/fetch-ghostty-themes.sh` で [mbadolato/iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) の `ghostty/` を `Resources/ghostty/themes/` に取得 → `project.yml` で folder reference として bundle → `GhosttyManager.configureResourcesDir()` が起動時（`ghostty_init` の前）に `GHOSTTY_RESOURCES_DIR` を `<bundle>/Contents/Resources/ghostty` に向ける（env に既にあれば尊重、無ければ `/Applications/Ghostty.app/...` にフォールバック）
- **確認**: 起動後 `grep -i ghostty /tmp/ide-poc.log` で `GHOSTTY_RESOURCES_DIR -> ...` が出ていて、`theme "..." not found` の diagnostic が消えていれば OK
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
- **確認**: `grep "ghostty" /tmp/ide-poc.log` で `loaded bundled config: ...` の行が出る。user 設定で font-family を override しているケースは `user config has font-family; reset bundled font-family list` も追加で出る。`config diagnostics: 0` なら parse error なし

---

## キー入力の優先順位

詳細は [ARCHITECTURE.md](./ARCHITECTURE.md#キー入力の優先順位)。

要点だけ:
- **NSEvent.addLocalMonitorForEvents（MRUKeyMonitor）が最優先**。Ctrl+M / Cmd+P / Cmd+Shift+F / Cmd+J / (ツリーにフォーカス時) Cmd+R は vim/claude の中でも握る
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
Sources/ide/
├─ IdeApp.swift / ContentView.swift / RootLayoutView.swift / CenterPaneView.swift  アプリ全体
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
