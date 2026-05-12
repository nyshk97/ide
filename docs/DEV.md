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

## 動作確認スクリプト

| スクリプト | 用途 |
|---|---|
| `scripts/ide-launch.sh [wait_seconds]` | ide を kill してから起動。デフォルト 3 秒待機 |
| `scripts/ide-keystroke.sh [--enter|--keycode N] "text"` | osascript（補助アクセス権限が必要）でキー送信 |
| `scripts/ide-screenshot.sh <path>` | `CGWindowList` でウィンドウ ID を引いて `screencapture -l` でキャプチャ（取れなければメイン画面全体にフォールバック） |

- **TCC（プライバシー）権限の罠**: `osascript` / `screencapture` は SIP 配下のバイナリで、IDE 内ターミナル（Ghostty）はシェルを `/usr/bin/login` 経由で起動する。この `login` のせいで TCC の「責任プロセス」が IDE.app に解決されず、`osascript`/`screencapture` 自体に権限を求めるポップアップが毎回出る（恒久付与できない）。`ide-screenshot.sh` は `osascript` を捨てて `CGWindowList`（補助アクセス不要）+ `screencapture -l` にしてあるので「アクセシビリティ」のポップアップは出ない（「画面収録」は依然必要）。`ide-keystroke.sh` は合成キー入力のため補助アクセスが不可避。**キーストローク込みの検証を安定して回したいなら、IDE の中ではなく Terminal.app / iTerm から実行**し、そのターミナルアプリに一度「アクセシビリティ」「画面収録」を付与する（普通に署名された安定アプリ & `login` 介在なしなので付与が効き続ける）。
- **Claude Code の Bash 環境からは画面収録権限が無い**ので `ide-screenshot.sh` も `could not create image from display` で落ちる。エージェント側の検証は `/tmp/ide-poc.log`（PocLog）・起動ログ・テスト用環境変数に倒し、目視スクショが要るものはユーザーに依頼する

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
| `IDE_TEST_TOAST=<message>` | 起動時に赤 toast を出す |
| `IDE_TEST_UNREAD_INDICES=0,2` | 起動時に N 番目（allOrdered = pinned + temporary）のプロジェクトの workspace を作り、下ペインのカレントタブに未読通知を立てる（サイドバーのリング表示の検証用）。`IDE_TEST_AUTO_ACTIVATE_INDEX` と同じインデックスを指すと「アクティブ化でその表示タブの未読が消える」挙動も確認できる |

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
| `/tmp/ide-poc.log` | デバッグ用。`init()` で reset、`PocLog.write` で追記。`tail -f` で追える |
| `~/Library/Logs/ide/ide-YYYY-MM-DD.log` | 永続ログ（step12〜）。日次ローテーション、7 日 / 50MB 超で削除 |

`PocLog.write` は内部で `Logger.debug` にも転送するので、step12 以降は `~/Library/Logs/ide/` も併せて見る。PocLog は `Logger` へ一本化して撤去予定（[BACKLOG.md](./BACKLOG.md)）。

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

---

## SwiftUI まわりのクセ

- **`HSplitView` の初期幅は固定 `idealWidth` で決める**: 固定値の `idealWidth` は効くが、`GeometryReader` でウィンドウ幅に対する比率（中央=残り幅の 40% 等）で算出すると、起動直後・全画面遷移直後に `GeometryReader` が一瞬小さいサイズを返した時点でペイン幅が確定し、以降のリサイズ分は伸縮制約のないペイン（右）に吸われて狭いまま固定される。`maxWidth` で起動時の幅を絞り、伸ばしたいペインだけ無限にする（[RootLayoutView.swift](../Sources/ide/RootLayoutView.swift)）
- **再帰的な `@ViewBuilder`**: opaque type 推論が壊れるので、データ側で flatten するか `AnyView` に逃がす（[FileTreeView.swift](../Sources/ide/FileTreeView.swift) の `flattenedNodes()`）
- **`.background(Subview)` 内の `@ObservedObject`** は外側 body の再描画に伝播しない: 監視したい型は `body` を持つ View 自身に `@ObservedObject` で持たせる
- **深くネストした `@Published` は親の `@ObservedObject` まで伝播しない**: `ProjectsModel`→`WorkspaceModel`→`PaneState`→`TerminalTab.@Published` の葉を変えても、`ProjectsModel` だけ `@ObservedObject` する View は再描画されない。監視対象の型に派生 `@Published`（`unreadProjectIDs` 等）を持ち、葉を変える全箇所から再計算メソッド（`refreshUnreadProjects()`）を呼ぶ。init で値を入れてから View 初描画なら通知不要だが、後から変わるなら必須
- **`.overlay` / `.background` でフレーム外に描いた分はクリップされうる**: `ScrollView` 等の中で `Circle().stroke(...).padding(-N)` のように外側へリングをはみ出させても見えないことがある。フレーム内に確実に描くなら `Circle().strokeBorder(...)`（縁を内側に引く）か、内側コンテンツを inset してリング用の余白を作る
- **AppleScript の `click at {x, y}`** は SwiftUI の `onTapGesture` に届かないことがある（カスタムタブバー等の `Button` も同様に反応しないことがある）: 動作確認は `IDE_TEST_*` 環境変数 or 座標連打で迂回、本格的な hit test は手動確認に倒す。入力を送る `osascript` は毎回 `set frontmost to true` から始める（osascript 終了でフォーカスが呼び出し元ターミナルに戻るので、複数呼び出しに分けると2発目以降が IDE に届かない）。`keystroke "..."` の直後に `key code 36`（Enter）を続けると Ghostty 端末で Enter が落ちることがある → Enter は別 osascript で、効かなければ2回送る
- **`URL` の `==` は scheme/baseURL の差で一致しないことがある**: 比較は `URL.standardizedFileURL.path`（String）で行う
- **NSView の自動 `becomeFirstResponder` 時は `NSApp.currentEvent` が nil**: 起動時に SplitView が NSHostingController を組み立てる過程で、最初に追加された NSView が自動で firstResponder になる。`WorkspaceModel.init` で設定した初期 `activePane = bottomPane` を上書きされたくない場合は、`becomeFirstResponder` 内で `NSApp.currentEvent?.type` が `.leftMouseDown` / `.keyDown` 等のユーザー操作起因のときだけ `setActive` を呼ぶ（[GhosttyTerminalView.swift](../Sources/ide/GhosttyTerminalView.swift) の `isUserDrivenFirstResponderChange()`）
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

---

## キー入力の優先順位

詳細は [ARCHITECTURE.md](./ARCHITECTURE.md#キー入力の優先順位)。

要点だけ:
- **NSEvent.addLocalMonitorForEvents（MRUKeyMonitor）が最優先**。Ctrl+M / Cmd+P / Cmd+Shift+F は vim/claude の中でも握る
- `Ctrl+M` は `keyCode == 46` で判定（macOS が Ctrl+letter を CR にマップする問題回避）

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
