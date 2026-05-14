# DiffViewer 機能を IDE に統合

## 概要・やりたいこと

`~/diff-viewer` 相当の機能を IDE 本体に統合し、既存 DiffViewer の利用は終了する。

要点:
- 対象は **今アクティブなプロジェクト 1 つだけ**（DiffViewer は複数 repo 横断だが、IDE 版は単一 repo）
- 中央ペインのツールバー（[←][→][🌲ツリーへ] の並び）に diff ボタンを **常時表示**。差分の有無で見た目を変える（差分なし: アイコン薄め・件数なし／差分あり: アイコン通常色 + 件数バッジ）。判定は `GitStatusModel.statuses.count` を直に見る
- diff ボタンクリック / `Cmd+D` で **中央ペイン overlay** として Diff UI を表示（`FullSearchView` と同じ作法、Esc で閉じる）。差分なし状態で開いた時は "変更なし" を表示
- diff の中身は **overlay を開いた瞬間に `git diff` を実行**（先読みしない）。開いてる間の手動再ロードは `Cmd+R`
- staged / unstaged / untracked / deleted / rename を **全部混ぜて 1 リスト**（DiffViewer と同じ挙動）
- 配色・サイドバイサイド表示は DiffViewer の `FileDiffView` / `SideBySideDiffView` を**単一 repo 用に縮めて移植**

## 前提・わかっていること

### 既存資産（IDE 側）

- `GitStatusModel`（`Sources/ide/GitStatusModel.swift`）: 3 秒ポーリングで `git status --porcelain=v1 -z -uall` を保持。`statuses: [String: Badge]` を `@Published`。**バッジ表示判定 + 件数はこれをそのまま流用**
- `FileTreeModel.gitStatus`: プロジェクトごとに 1 つ持っているので `projects.fileTree(for: project).gitStatus` で取れる
- `FullSearchView`（`Sources/ide/FullSearchView.swift`）: `RootLayoutView` で `projects.fullSearchVisible` をトリガに overlay 表示。**この作法を踏襲**（mount は `RootLayoutView`、状態は `ProjectsModel`、トリガは `MRUKeyMonitor`）
- `MRUKeyMonitor`: 局所キー監視。`Cmd+Shift+F`（keyCode 3 + [.command, .shift]）と同じ要領で `Cmd+Shift+D`（keyCode 2）を握る
- `ProcessRunner.run(executable:arguments:cwd:timeout:)` + `BinaryLocator.git`: `git` 実行のお作法は確立済み

### 流用元（DiffViewer 側）

- `Services/GitService.swift`（240行）: `fetchDiffs` / `fetchFullFileDiff` / `parseDiff` / rename マッチ / untracked / deleted の処理一式
- `Views/FileDiffView.swift`（169行）: 1 ファイルの diff カード
- `Views/SideBySideDiffView.swift`（93行）: サイドバイサイドの 1 hunk 表示
- `Views/RepositorySection.swift`（28行）: 単一 repo を縦に並べる入れ物（複数 repo タブバーは要らない）
- `Views/EmptyStateView.swift`（16行）, `ImagePreviewView.swift`（84行）: 補助
- 配色 `GitHubDark` は DiffViewer 専用テーマ。IDE の他 view は標準色なので、**diff overlay だけ GitHub ライクな配色を保持する**方が見やすい想定（移植時に流用する）

### 設計の判断ポイント（会話で決定済み）

| 論点 | 決定 |
|---|---|
| マーク場所 | 中央ペインのツールバー |
| マーク表示条件 | 常時表示。差分なしは薄め・件数なし／差分ありは通常色 + 件数バッジ |
| Diff UI 形式 | 中央ペイン overlay（Esc で閉じる） |
| ショートカット | `Cmd+D`（`MRUKeyMonitor` で先に握る。Ghostty デフォルトの `cmd+d=new_split:right` と競合するが ide は libghostty の split を使っていないので実害なし） |
| diff 取得 | overlay 開いた瞬間に `git diff`、`Cmd+R` で再取得 |
| staged/unstaged/untracked | 全部混ぜて 1 リスト |
| ステート保持 | overlay を閉じたら diff キャッシュは破棄（再度開いたら取り直し） |

### 残っている小さい未決事項

- バッジボタンのアイコンとラベル: `Image(systemName: "plus.forwardslash.minus")` or `Image(systemName: "rectangle.split.3x1")` など。差分ありの件数バッジは DiffViewer の `RepositoryTab`（青系 Capsule）と同じ作法で。実装中に良い見た目を選ぶ
- overlay のサイズ: `FullSearchView` は 560pt だが diff はもっと広く要る。中央ペイン幅の 90% くらい・高さ 80% くらいで `.frame(maxWidth:, maxHeight:)` する想定
- バイナリ判定: DiffViewer は `try? String(contentsOfFile:)` で読めなければバイナリ扱い。移植時もそのまま

## 実装計画

### Phase 1: DiffViewer の core を移植する [AI🤖]

- [x] `Sources/ide/Diff/` ディレクトリを作成
- [x] `DiffModels.swift` 新規: `FileDiff` / `DiffHunk` / `DiffLine` / `FileChangeType` / `DiffStage` を DiffViewer から移植（複数 repo を扱う `RepositoryDiff` は **入れない**、単一 repo なので `[FileDiff]` で十分）
- [x] `DiffService.swift` 新規: DiffViewer の `GitService` を縮めて移植
  - `fetchDiffs(repoPath: URL) -> [FileDiff]`: unstaged + staged + untracked + deleted + rename を 1 リストで返す
  - `fetchFullFileDiff(fileName:repoPath:stage:changeType:) -> [DiffHunk]`: ファイルカードを開いたとき用
  - `git` 実行は `ProcessRunner` + `BinaryLocator.git` を使う（DiffViewer の素の `Process` 直叩きから差し替え）
  - 10 秒タイムアウトを付ける（`GitStatusModel` と揃える）
- [x] `DiffViewModel.swift` 新規: overlay 用の `@MainActor ObservableObject`
  - `@Published files: [FileDiff]`
  - `@Published isLoading: Bool`, `errorMessage: String?`
  - `load(project: Project)` / `reload()`
  - 失敗時は `ErrorBus.shared.notify(_:kind:)` で toast を出す
- [x] `GitHubDark.swift` 新規: DiffViewer の配色定数だけ移植（diff overlay 専用テーマとして閉じる、IDE の他 view には触らない）

### Phase 2: バッジボタンを中央ペインのツールバーに追加 [AI🤖]

- [x] `CenterPaneView` の上部に **共通の薄い上部バー**（高さ ~28pt）を新設する
  - 現状の [←][→][🌲] は `FilePreviewView.toolbar` の中にあり、**プレビュー時しか出ない**。ユーザーの要望はツリー / プレビューどちらでも diff ボタンを見せること（2026-05-14 確認済み）
  - 既存のプレビューツールバーは触らず、共通バーを上に重ねる（プレビュー時は 2 段になるが許容）
  - ファイルツリーが空（プロジェクトが選択されてない）状態では共通バーも出さない
- [x] 共通バーの右端に diff ボタンを **常時** 追加
  - 差分なし（`gitStatus.statuses.count == 0`）: アイコンのみ・`.secondary` 系の低 opacity
  - 差分あり（`gitStatus.statuses.count > 0`): アイコン通常色 + 件数を `Capsule` で表示
  - クリックで `projects.diffOverlayVisible = true`（差分なしでも開ける、"変更なし" が出る）
  - hover state あり（既存ボタンのスタイルに合わせる）
- [x] `ProjectsModel` に `diffOverlayVisible: Bool` を追加（`fullSearchVisible` のすぐ近くに）

### Phase 3: Diff overlay の UI を組む [AI🤖]

- [x] `Sources/ide/Diff/DiffOverlayView.swift` 新規
  - 構造: 上部にタイトル + ファイル数 + reload ボタン、本体に `ScrollView { LazyVStack { ForEach(files) { FileDiffCard(...) } } }`
  - `FullSearchView` と同じ `.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))` + shadow
  - サイズ: 中央ペイン内で `.frame(maxWidth: .infinity, maxHeight: .infinity).padding(...)` で大きめに広げる
  - `onAppear` で `viewModel.load(project:)` を呼ぶ
- [x] `FileDiffCard.swift` 新規: DiffViewer の `FileDiffView` を流用（複数 repo の概念を削る）
  - ファイル名 + 変更タイプバッジ + hunks の縦並び
  - クリックで全行展開（`fetchFullFileDiff` を呼ぶ）
- [x] `SideBySideDiffRow.swift` 新規: DiffViewer の `SideBySideDiffView` を移植
- [x] `RootLayoutView` に `if projects.diffOverlayVisible { DiffOverlayView(...) }` を追加（`FullSearchView` の隣）
- [x] 「変更なし」状態のハンドリング: `viewModel.files.isEmpty && !isLoading` なら "変更なし" メッセージを中央に表示。**差分なしでも overlay は開けるので、これは通常経路**（クリーン状態の確認用途）

### Phase 4: ショートカットと終了処理を繋ぐ [AI🤖]

- [x] `MRUKeyMonitor` に `Cmd+D`（mods == `.command`, keyCode 2 = D）を追加
  - `Cmd+Shift+F` のすぐ下、同じ作法で
  - `addLocalMonitorForEvents` で先に握るので、ターミナルにフォーカスがあっても Ghostty 側の `cmd+d=new_split:right` より優先される
  - overlay 表示中は `Cmd+D` で **トグル**（もう一度押すと閉じる）
- [x] overlay 表示中の Esc で `projects.diffOverlayVisible = false`（MRUKeyMonitor 側に追加、既存 MRU の Esc 処理と同じパターン）
- [x] overlay 表示中の `Cmd+R` で `viewModel.reload()`
  - **既存の `Cmd+R`（fileTreeFocused 限定）と競合しないように**、`diffOverlayVisible` が立ってる時はこちらを優先する
- [x] overlay を閉じたら `viewModel.files = []` でメモリを解放（次に開いたとき取り直し）

### Phase 5: 仕上げ [AI🤖]

- [x] `mise run build` を通す
- [x] `IDE_TEST_AUTO_OPEN_DIFF` 環境変数を追加（任意）: 起動時にアクティブプロジェクトの diff overlay を自動で開く。動作確認用。`docs/DEV.md` の `IDE_TEST_*` 一覧に追記
- [x] `VERIFY.md` に diff overlay の確認手順を追加（バッジ表示確認 / Cmd+Shift+D 開閉 / Cmd+R 再ロード / Esc 終了）
- [x] `docs/BACKLOG.md` の「当面やらない > AI 連携」セクションの近くに **DiffViewer 統合は完了**とは書かない（解決済みは BACKLOG から消すルール）。代わりに `README.md` のスクリーンショット or 機能リストに 1 行追記する程度
- [x] `~/diff-viewer/` のリポジトリは**そのまま残す**（IDE から完全に独立しているので削除は別途ユーザー判断）

### 動作確認 [AI🤖 → 人間👨‍💻]

AI で完結する確認:
- [x] `mise run build` 通過
- [x] `./scripts/ide-launch.sh` で起動、`IDE_TEST_AUTO_ACTIVATE_INDEX=0` で固定プロジェクトをアクティブに
- [x] `./scripts/ide-screenshot.sh /tmp/diff-badge-empty.png` で **差分なし状態**（test fixture をクリーン）の diff ボタンが薄く表示されることを確認
- [x] test fixture に変更を仕込んだ上で再起動 → `./scripts/ide-screenshot.sh /tmp/diff-badge-on.png` で **差分あり状態** の diff ボタンが通常色 + 件数バッジになることを確認
- [x] `IDE_TEST_AUTO_OPEN_DIFF=1` で起動 → screenshot で overlay の見た目を確認

人間に依頼する確認:
- [ ] `Cmd+D` で開閉できる（`ide-keystroke.sh` は IDE 内から動かないので目視）
- [ ] **ターミナルにフォーカスがある状態**でも `Cmd+D` が overlay 起動になることを確認（Ghostty 側で split が走らない）
- [ ] バッジクリックで開く
- [ ] `Cmd+R` で再ロードが効く
- [ ] Esc で閉じる
- [ ] hunk の展開（クリック）と全行表示
- [ ] バイナリファイル / 画像ファイルが落ちずに表示される

## ログ

### 試したこと・わかったこと
- 2026-05-14: 中央ペインの既存ツールバー [←][→][🌲] は `FilePreviewView.toolbar` 内にあり、プレビュー表示時しか出ないことを確認。ツリー表示時にも diff バッジを見せたい要望に応えるには CenterPaneView 直下に共通バーを新設する必要がある
- 2026-05-14: `DiffSyntaxHighlighter` の `ruleCache` が Swift 6 strict concurrency で「nonisolated global shared mutable state」エラーになった → enum 全体に `@MainActor` を付けて解決（SwiftUI body から呼ぶ前提なので OK）
- 2026-05-14: 動作確認 OK。差分あり(14件)・差分なし・overlay 表示すべて screenshot で確認できた（`/tmp/diff-badge-on.png`, `/tmp/diff-badge-empty.png`, `/tmp/diff-overlay.png`）。Cmd+D / Esc / Cmd+R は IDE 内 Claude Code から ide-keystroke.sh が動かないので手動確認待ち

### 方針変更
- 2026-05-14: Phase 2 のバッジ設置場所を「既存ツールバーに追加」→「CenterPaneView 直下に共通バーを新設」に変更。理由: 既存ツールバーがプレビュー時限定だったため、ツリー時にも常時表示する要件を満たすには別バーが必要
