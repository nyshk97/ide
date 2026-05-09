# ARCHITECTURE

ide の主要モジュールとデータフロー。コードを読む前の地図として使う。

詳細はソース本体を読むのが正、ここはあくまで道しるべ。

---

## 全体図

```
┌──────────────────────────────────────────────────────────────────────┐
│ IdeApp (SwiftUI @main)                                               │
│ └─ ContentView                                                       │
│    └─ RootLayoutView (HSplitView)                                    │
│       ├─ LeftSidebarView (プロジェクト一覧 + 「+」ボタン)            │
│       ├─ CenterPaneView                                              │
│       │  ├─ FileTreeView (FileTreeModel)                             │
│       │  └─ FilePreviewView (FilePreviewModel)                       │
│       └─ rightArea (ZStack で各 project の WorkspaceView を重ね opacity)│
│          └─ WorkspaceView (VSplitView)                               │
│             ├─ TabsView(top)                                         │
│             └─ TabsView(bottom)                                      │
│                └─ GhosttyTerminalView (NSViewRepresentable)          │
└──────────────────────────────────────────────────────────────────────┘
```

`overlay` として MRU 切替 / Cmd+P / Cmd+Shift+F / Toast が乗る。

---

## 中心: ProjectsModel

**`ProjectsModel.shared`**（singleton, `@MainActor`）が IDE のほぼ全ての状態を持つ。

```
ProjectsModel
├─ pinned: [Project]                  # ピン留め群（永続化）
├─ temporary: [Project]                # 一時群（プロセス内のみ、MRU 順）
├─ activeProject: Project?             # 現在 active なプロジェクト
├─ workspaces:  [UUID: WorkspaceModel] # プロジェクト別ターミナル
├─ fileTrees:   [UUID: FileTreeModel]  # プロジェクト別ファイルツリー
├─ previews:    [UUID: FilePreviewModel] # プロジェクト別プレビュー
├─ fileIndexes: [UUID: FileIndex]      # プロジェクト別 Cmd+P インデックス
├─ mruStack: [UUID]                    # Ctrl+M MRU 候補
├─ mruOverlay: MRUOverlayState?        # Ctrl+M overlay 状態
├─ quickSearch*: …                     # Cmd+P overlay 状態
└─ fullSearch*: …                      # Cmd+Shift+F overlay 状態
```

各サブモデル（WorkspaceModel / FileTreeModel / FilePreviewModel / FileIndex）は **プロジェクト単位で生成**され、`close(project:)` まで dictionary に保持される。これにより:

- プロジェクト切替時、既存の shell プロセス・ファイルツリー展開状態・プレビュー履歴が **生きたまま**残る（要件「ターミナルセッションは生きっぱなし」）
- `RootLayoutView` の右ペインは `ZStack` で全 project の `WorkspaceView` を重ねて `opacity` で切替（NSView を destroy しない）

---

## モデル責務

### Project / ProjectsStore

- `Project`: `id` / `path` / `displayName` / `isPinned` / `lastOpenedAt` の値型。Codable。`isMissing` は computed（FileManager で path 存在チェック）
- `ProjectsStore`: `~/Library/Application Support/ide/projects.json` への永続化。アトミック書き込み（temp → rename）+ バックアップ世代 `.1` 〜 `.3`。schemaVersion: 1。
- 一時プロジェクトは保存対象外。

### WorkspaceModel / PaneState / TerminalTab

- `WorkspaceModel`: 1 プロジェクト分の上下 2 ペイン（`topPane` / `bottomPane`）と `activePane`
- `PaneState`: 1 ペイン分のタブ群。`tabs: [TerminalTab]` と `activeIndex`
- `TerminalTab`: 1 タブ = 1 surface = 1 shell プロセス。`title` / `lifecycle (alive | exited)` / `cwd` / `foregroundProgram (claude/codex/...)` / `hasUnreadNotification`

```
WorkspaceModel(project: ide)
├─ topPane (PaneState)
│  └─ tabs: [shell 1, shell 2]
└─ bottomPane (PaneState)
   └─ tabs: [shell 1]
```

### GhosttyManager / GhosttyTerminalView

- `GhosttyManager.shared`: ghostty C ライブラリ（ghostty-internal.a）の lifecycle。`ghostty_app_t` を 1 つ持ち、surface の register/unregister や action callback (BEL / EXIT / OPEN_URL) を捌く
- `GhosttyTerminalView` (NSViewRepresentable) → `GhosttyTerminalNSView`: 1 surface 分の Metal レイヤ。`+TextInput.swift`（IME）と `+Mouse.swift` に分割
- `cfg.working_directory` に `tab.cwd` を渡してプロジェクトルートで shell が立ち上がる（要件 4）

### FileTreeModel / FileNode / GitIgnoreChecker

- `FileTreeModel`: プロジェクト 1 つ分のファイルツリー。**直下子のみ初期 scan**、ディレクトリは展開時に lazy scan（`.git` 等で固まらないため）
- `FileNode`: ファイル or ディレクトリ 1 ノード。`isSymlink` / `symlinkTarget` / `isIgnored`
- `GitIgnoreChecker`: `git check-ignore --stdin -z --verbose --non-matching` を argv 配列で起動して `.gitignore` 判定をバッチ処理

### GitStatusModel

- 3 秒間隔の `Timer` で `git status --porcelain=v1 -z -uall` を回し、結果を `[String: Badge]`（path → M/A/D/?/R）として保持
- 200ms debounce、10 秒タイムアウト
- FSEvents は Phase 2.5（[BACKLOG.md](./BACKLOG.md)）

### FilePreviewModel / FilePreviewClassifier / FilePreviewView

- `FilePreviewModel`: `currentURL` + 履歴ナビ（戻る/進む）
- `FilePreviewClassifier`: URL → `FilePreviewKind`（code / markdown / image / pdf / binary / tooLarge / external / error）。NUL 検査でバイナリ判定、5MB 超は確認、50MB 超は外部誘導
- `FilePreviewView`: 種別ごとに `CodePreview`（NSTextView）/ `MarkdownPreview`（AttributedString）/ `ImagePreview`（NSImage）/ `PDFPreview`（PDFKit）

### FileIndex / QuickSearchView (Cmd+P)

- `FileIndex`: project 全体を `FileManager.enumerator` で再帰スキャン（hidden / package descendants は除外、`.git` `node_modules` 等は skip）
- 自前のファジーマッチ（隣接 / 先頭 / 全文字順ボーナス）
- `recents: [URL: Date]` で直近開いたファイルを上位スコアに

### FullTextSearcher / FullSearchView (Cmd+Shift+F)

- `grep -rnIH -F --exclude-dir=…` を `Process` で起動（要件 8.1: argv 配列）
- 10 秒タイムアウト、上限 1000 件
- ripgrep への切替は Phase 2.5

### MRUKeyMonitor

- `NSEvent.addLocalMonitorForEvents` でアプリ全体のキー入力を**最優先**で握る
- `Ctrl+M` / `Cmd+P` / `Cmd+Shift+F` / overlay 表示中の `Esc` `↑` `↓`
- Ghostty NSView の `performKeyEquivalent` より先に呼ばれるので、vim/claude 等の TUI 内でも IDE が捕捉できる（要件 3）
- `Ctrl+M` の判定は `keyCode == 46`（macOS が `Ctrl+letter` を CR にマップする問題回避）

### Logger / PocLog / ErrorBus

- `Logger.shared`: `~/Library/Logs/ide/ide-YYYY-MM-DD.log` への永続化。日次ローテーション + 7 日 / 50MB 超で削除
- `PocLog`: `/tmp/ide-poc.log` への並走出力（Phase 1 から残るデバッグ用）。内部で `Logger.debug` に転送している。Phase 2.5 で撤去予定
- `ErrorBus.shared`: 単発 toast 用 ObservableObject（要件 8.3）。継続的な状態異常は各 View 内で常駐表示する使い分け

---

## キー入力の優先順位

```
NSEvent.addLocalMonitorForEvents (MRUKeyMonitor)
  → Ctrl+M / Cmd+P / Cmd+Shift+F / overlay 中の Esc/↑/↓ を握って終了
  ↓
SwiftUI の View 階層
  → SwiftUI Button の keyboardShortcut（プレビューの「← ツリーに戻る」「VSCode で開く」 等）
  ↓
NSWindow の標準 menu chain
  → メニューバーの Cmd+T / Cmd+W / Cmd+Q / Help > 最近のログを開く（Cmd+Shift+L）
  ↓
GhosttyTerminalNSView.performKeyEquivalent
  → Cmd+T / Cmd+W はここで握って ProjectsModel.activeWorkspace.activePane に流す
  ↓
GhosttyTerminalNSView.keyDown
  → IME 含めて surface に流す（NSTextInputClient + ghostty_surface_key）
```

---

## ビルド・依存

- **XcodeGen**: `project.yml` を source-of-truth に `ide.xcodeproj` を生成（gitignore 対象）。新規 .swift ファイル追加後は `mise run regen`（`mise run build` の前段で自動実行）
- **GhosttyKit.xcframework**: ghostty fork のビルド成果物。リポジトリにバイナリでコミット済み
- **system frameworks**: Metal / QuartzCore / IOSurface / UniformTypeIdentifiers / Carbon / PDFKit
- **Swift 6 strict concurrency**: 既知の罠は [DEV.md](./DEV.md) と CLAUDE.md にまとめてある
