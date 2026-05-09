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
| `scripts/ide-keystroke.sh [--enter|--keycode N] "text"` | osascript でキー送信 |
| `scripts/ide-screenshot.sh <path>` | フロントウィンドウだけを `screencapture -x -R` でキャプチャ |

詳しい確認手順は [VERIFY.md](../VERIFY.md)。

---

## テスト用環境変数

VERIFY 用に起動時の状態を仕込めるフラグ。**本番ユーザーは設定しない**前提。
すべて `~/Library/Application Support/ide/projects.json` にピン留めが事前に書かれていることを前提にする。

| 環境変数 | 効果 |
|---|---|
| `IDE_TEST_AUTO_ACTIVATE_INDEX=N` | 起動時に N 番目のピン留めをアクティブ化（要件「再起動時は active を復元しない」を VERIFY で迂回するため） |
| `IDE_TEST_AUTO_PREVIEW=<rel-path>` | active project からの相対パスでプレビューを開く |
| `IDE_TEST_AUTO_FULLSEARCH=<query>` | 起動時に Cmd+Shift+F の overlay を開いて grep を実行（TextField.onSubmit が AppleScript の Enter で発火しないため） |
| `IDE_TEST_TOAST=<message>` | 起動時に赤 toast を出す |

例:
```bash
IDE_TEST_AUTO_ACTIVATE_INDEX=0 \
IDE_TEST_AUTO_PREVIEW="REQUIREMENTS.md" \
  /tmp/ide-build/Build/Products/Debug/ide.app/Contents/MacOS/ide
```

`open -n` 経由では env を渡せないので、バイナリを直接叩くのが確実。

---

## ログの見方

| ログファイル | 用途 |
|---|---|
| `/tmp/ide-poc.log` | デバッグ用。`init()` で reset、`PocLog.write` で追記。`tail -f` で追える |
| `~/Library/Logs/ide/ide-YYYY-MM-DD.log` | 永続ログ（step12〜）。日次ローテーション、7 日 / 50MB 超で削除 |

`PocLog.write` は内部で `Logger.debug` にも転送するので、step12 以降は `~/Library/Logs/ide/` も併せて見る。Phase 2.5 で PocLog は撤去予定（[BACKLOG.md](./BACKLOG.md)）。

---

## Swift 6 strict concurrency の落とし穴

過去に踏んだもののまとめ:

- **NSView 配下で C ポインタを `deinit` から触る**: `nonisolated(unsafe) private var ptr: SomePointerType?` が必要
- **`Timer` プロパティを `deinit` から `invalidate()`**: `nonisolated(unsafe)` でラップ
- **AppKit プロトコル（NSTextInputClient 等）への準拠**: `extension X: @preconcurrency Protocol`
- **`Timer.scheduledTimer` の closure**: nonisolated なので `Task { @MainActor in ... }` でメインに戻す
- **`MainActor.assumeIsolated` を background queue から呼ぶとサイレントクラッシュ**: 値は MainActor 上で先に capture する
- **`@unchecked Sendable` で struct を fix**: ただし non-Sendable な stored property（`FileManager` 等）は computed property で逃がす

---

## SwiftUI まわりのクセ

- **`HSplitView` は `idealWidth` を尊重しない**: 初期は均等分割になりがち。`maxWidth` で起動時の幅を絞り、伸ばしたいペインだけ無限にする（[RootLayoutView.swift](../Sources/ide/RootLayoutView.swift)）
- **再帰的な `@ViewBuilder`**: opaque type 推論が壊れるので、データ側で flatten するか `AnyView` に逃がす（[FileTreeView.swift](../Sources/ide/FileTreeView.swift) の `flattenedNodes()`）
- **`.background(Subview)` 内の `@ObservedObject`** は外側 body の再描画に伝播しない: 監視したい型は `body` を持つ View 自身に `@ObservedObject` で持たせる
- **AppleScript の `click at {x, y}`** は SwiftUI の `onTapGesture` に届かないことがある: 動作確認は `IDE_TEST_*` 環境変数 or 座標連打で迂回、本格的な hit test は手動確認に倒す
- **`URL` の `==` は scheme/baseURL の差で一致しないことがある**: 比較は `URL.standardizedFileURL.path`（String）で行う

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
   ├─ BACKLOG.md         残タスク・Phase 2.5・Phase 3 アイデア
   ├─ DEV.md             ← この文書
   └─ plans/
      ├─ phase1-terminal.md
      └─ phase2-files.md
```

---

## ディレクトリ構成

```
Sources/ide/
├─ IdeApp.swift / ContentView.swift / RootLayoutView.swift  アプリ全体
├─ Project.swift / ProjectsModel.swift / ProjectsStore.swift  プロジェクト管理
├─ WorkspaceModel.swift / PaneState.swift / TerminalTab.swift  ターミナル
├─ GhosttyManager.swift / GhosttyTerminalView.swift / +Mouse / +TextInput  Ghostty ラッパ
├─ FileTreeModel.swift / FileNode.swift / FileTreeView.swift  ファイルツリー
├─ GitIgnoreChecker.swift / GitStatusModel.swift  git 連携
├─ FilePreviewModel.swift / FilePreviewView.swift  プレビュー
├─ FileIndex.swift / QuickSearchView.swift  Cmd+P
├─ FullTextSearcher.swift / FullSearchView.swift  Cmd+Shift+F
├─ MRUKeyMonitor.swift / MRUOverlayState.swift / MRUOverlayView.swift  Ctrl+M
├─ Logger.swift / Logging.swift  ログ
└─ ErrorBus.swift  toast
```
