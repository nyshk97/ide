# 4 カラムレイアウト化（ファイルツリーとプレビューを別ペインに分離）

## 概要・やりたいこと

現状のレイアウトは「プロジェクト一覧 | 中央（ツリー or プレビュー）| ターミナル」の 3 カラム。中央ペインはファイルツリーとプレビューを `ZStack + opacity` で切り替えており、ファイルを開くとツリーが見えなくなる。

複数の試用者からこの挙動に違和感（「ツリーが消えてしまう」）を指摘されている。一方で、プレビュー領域をファイル未オープン時にも常時占有させるのは横幅の無駄になるため避けたい。

そこで:

- **4 カラム化**（プロジェクト一覧 | ファイルツリー | プレビュー | ターミナル）に変更し、ファイルツリーは常駐させる
- **プレビューはアクティブプロジェクトごとに表示/非表示** する（プロジェクト A はプレビュー開、B は閉、のような独立状態）
- **プロジェクト一覧サイドバーは折りたたみ可能** にする（グローバル state）

これで Markdown プラン等を眺めながら右側でチャット、という典型ワークフローでチャット領域を侵食せず、かつツリーも常に見える。

## 前提・わかっていること

### 設計の確定事項（`/dig-lite` で議論済み）

- **NSSplitViewController を使う**: 既存の `RootLayoutView.ThreeColumnSplit` が NSSplitViewController を直接ラップする安定実装を持っており、リサイズ・autosave も既に AppKit ネイティブで動いている。これを 4 ペインに拡張する
- **ペインは常に 4 つ存在させ、`isCollapsed` で表示/非表示**: SplitViewItem を動的に add/remove するのではなく、`canCollapse = true` の SplitViewItem を常時 4 つ持ち、`isCollapsed` を toggle する方式。divider 数が変わらないため autosave のフォーマットも安定し、再表示時に前回幅も復元される
- **autosave 移行**: `polepole.rootSplit` → `polepole.rootSplit.v2` に切替えて既存ユーザーの幅は捨てる。配布規模が小さい現時点でのコスト最小選択
- **プレビュー幅はグローバル**: AppKit autosave に丸投げ。プロジェクトごと幅は実装しない
- **プレビュー表示状態は project ごと**: アクティブプロジェクトの `FilePreviewModel.currentURL` が source-of-truth。これを観察して `previewItem.isCollapsed` を flip
- **プレビュー中身は active project のものだけを単一マウント**: 右ペインと違って ZStack で全 project 常駐させてはいけない。`PreviewWebView` の `NSViewRepresentable` が `PreviewWebController.shared.webView`（singleton な WKWebView）を毎回返す実装になっており（`PreviewWebView.swift:311-319`）、複数の `FilePreviewView` を同時マウントすると同じ WKWebView が複数箇所に乗ってクラッシュ or 表示破綻する。active project の `FilePreviewView` だけを if-let で描画する。`FilePreviewModel` が project ごとに `currentURL` / 履歴 / find 状態を保持しているのでそこは復元できる。**scroll position は `FilePreviewModel` に保持されていない**ため、project 切替でスクロール位置はリセットされうる（必要なら別 plan で対応）
- **プレビュー閉じる Esc/Cmd+W はグローバルに握らない**: Cmd+W は Ghostty 側で active terminal tab close に使われており（`GhosttyTerminalView.swift:247`）、MRUKeyMonitor で全件横取りすると端末操作を壊す。プレビュー側の View にローカルなフォーカス判定 (`@FocusState` or NSResponder) を持たせ、プレビューにフォーカスがある時のみ捕捉する
- **サイドバー復帰 UI**: 左端に細いハンドル/ボタンを残してクリックで展開（ショートカットだけにはしない）

### 現状のコード前提

- `RootLayoutView.swift:124-256` の `ThreeColumnSplit` / `ThreeColumnSplitController` / `DragDetectingSplitView` が今の基盤
- `CenterPaneView.swift:78-97` の `ProjectCenterContent` がファイルツリー / プレビューの opacity 切替を担う。これを「ツリーペイン専属」と「プレビューペイン専属」に分解する
- ペイン幅の永続化は `autosaveName` + `UserDefaults` に依存（`RootLayoutView.swift:172-175` で hasAutosavedFrames を判定）
- diff overlay には既に Esc / Cmd+W ハンドリングあり（`MRUKeyMonitor.swift:72-73`）。プレビューの閉じる操作も整合させる
- ショートカットは `ShortcutsStore` の `ShortcutAction` enum に case 追加 + `FixedShortcuts.all` で衝突検出させる
- `AppPaths.subdirName` 経由でデータディレクトリを扱う規約あり（Brew 配布版とのデータ分離）

### 動作確認の前提

- `POLEPOLE_TEST_*` 環境変数で起動時に状態を仕込めるパターンが既存（CLAUDE.md / docs/DEV.md 参照）。新しいレイアウト状態用にもフラグを足す
- `./scripts/polepole-launch.sh` + `./scripts/polepole-screenshot.sh` で起動 → 撮影が定型化されている

## 実装計画

### Phase 1: 4 カラム NSSplitView 基盤 [AI🤖]

- [ ] `RootLayoutView` の `ThreeColumnSplit` を `FourColumnSplit`（または汎用 `MultiColumnSplit`）にリネーム + 4 ペイン版に書き換え
- [ ] `autosaveName` を `"polepole.rootSplit.v2"` に変更（既存幅は破棄）
- [ ] 4 ペインの `holdingPriority` / `minimumThickness` / `canCollapse` を設定:
  - 左サイドバー: `canCollapse = true`, holding 260
  - ツリーペイン: `canCollapse = false`, holding 250
  - プレビューペイン: `canCollapse = true`, 初期 `isCollapsed = true`, holding 245
  - 右ターミナル: `canCollapse = false`, holding 240（拡縮を吸う）
- [ ] `ThreeColumnSplitController` の初期比率ロジックを 4 ペイン版に拡張。プレビュー collapsed 時とそうでない時で残り幅の分配が変わる点に注意（初回起動時はプレビュー collapsed なので、実質「サイドバー + ツリー + ターミナル」3 領域への割当）
- [ ] `DragDetectingSplitView` の divider 検出ループはそのまま使えるはず（subviews 数に追従するため）。動作確認

### Phase 2: 中央ペインを 2 つに分解 [AI🤖]

- [ ] `CenterPaneView` を `FileTreePaneView`（ツリー専属）と `FilePreviewPaneView`（プレビュー専属）に分割
- [ ] `FilePreviewPaneView` は **active project の `FilePreviewView` のみを `if let active = activeProject` で描画**（右ペインの ZStack 常駐パターンは singleton WKWebView と相性が悪いので採用しない）。project 切替時は View が作り直されるが、`currentURL` / 履歴 / find 状態は `FilePreviewModel`（project ごとに永続）が保持。scroll 位置はリセットされる（許容）
- [ ] NSSplitViewItem 自体は常に存在させたまま、`NSHostingController.rootView` の差し替えで中身を切替える形にする（SplitViewItem を入れ替えると divider 位置が壊れる）
- [ ] `RootLayoutView` の `FourColumnSplit` に渡す 4 closure を `LeftSidebarView` / `FileTreePaneView` / `FilePreviewPaneView` / `rightArea` に
- [ ] 上部の diff バッジボタン（`centerTopBar`）はツリーペイン側に残す（ツリーが常駐になるため。プレビュー側にも別途必要か実装中に確認）
- [ ] 旧 `ProjectCenterContent` は削除

### Phase 3: プレビュー表示/非表示の同期 [AI🤖]

- [ ] **観察の橋渡しに注意**: `ProjectsModel` の `activeProject` 観察だけでは preview 中身（`currentURL` 等）の変化を取れない。既存 `CenterPaneView.swift:72-78` のコメント「親では preview を観察できないため子 View にしている」と同じ落とし穴
- [ ] 対応策として **`ProjectsModel` に派生 `@Published var activePreviewVisible: Bool` を追加**し、以下のように同期する（`import Combine` 明記）:
  - `$activeProject` の sink で、新しい active の `preview.$currentURL` を購読し直し、古い購読は破棄
  - 購読は `private var previewCancellable: AnyCancellable?` で保持（差し替え時に自動 cancel）
  - **購読張り替え直後に初期値を反映**: 新 active の `currentURL` を即座に `activePreviewVisible` に書き込む（sink だけだと購読開始時の値が漏れる）
  - active が `nil` のときは `activePreviewVisible = false`
- [ ] `RootLayoutView` 側は `projects.activePreviewVisible` を `@Published` 経由で観察し、`updateNSViewController` で `previewItem.isCollapsed = !activePreviewVisible` を反映。**`animator()` 経由は使わない**（drag 中との競合を避けるため即時切替）
- [ ] アクティブプロジェクト切替時にもプレビュー状態が追従するか確認（A=プレビュー開、B=閉 で切替えて検証）

### Phase 4: サイドバー折りたたみ + 復帰ハンドル [AI🤖]

- [ ] グローバル state を 1 箇所に置く: `LayoutStore`（新規 ObservableObject）or `ProjectsModel` に `sidebarCollapsed: Bool` を追加。UserDefaults で永続化
- [ ] `RootLayoutView` から `sidebarCollapsed` を観察し、SplitViewItem の `isCollapsed` に反映
- [ ] サイドバー collapsed 中だけ表示する**復帰ハンドル View** を `RootLayoutView` の overlay として左端に重ねる（幅 12px 程度、`>` アイコン、ホバーで強調）。クリックで `sidebarCollapsed = false`
- [ ] **overlay の hit testing に注意**:
  - `zIndex` を明示（divider より手前、modal overlay より奥）
  - 復帰ハンドル非表示時は `allowsHitTesting(false)` にして、左端 divider のドラッグを邪魔しない
  - 表示時は逆に divider への mouse 当たり判定が上書きされないか確認（必要なら overlay 幅を divider 厚より少しずらす）
- [ ] `ShortcutAction` に `.toggleSidebar` を追加し、`ShortcutAction.defaults` に初期キー（候補: `Cmd+Shift+S`、`Cmd+0` 等 — 実装中に既存固定キーとの衝突を確認して決める）
- [ ] `MRUKeyMonitor` で `ShortcutsStore.shared.matches(event, .toggleSidebar)` を捕捉して toggle
- [ ] `FixedShortcuts.all` の更新は不要（リバインド可能 path）

### Phase 5: プレビュー閉じる UX [AI🤖]

- [ ] **MRUKeyMonitor で Cmd+W / Esc をグローバル捕捉してはいけない**: Cmd+W は Ghostty active terminal tab close（`GhosttyTerminalView.swift:247`）に使われており、横取りすると端末操作を壊す。Esc も TUI の通常入力なので奪わない
- [ ] **既存の `.keyboardShortcut(.escape, modifiers: [])`（`FilePreviewView.swift:130`）はフォーカス判定を保証しない**ので、そのまま残すと「端末にフォーカスしているのに Esc でプレビューが閉じる」事故が起きる
- [ ] 採用方針: **NSResponder ラッパで明示的にフォーカスゲート化する**:
  - `FilePreviewView`（or その root container）を `NSHostingView` サブクラスで包み、`acceptsFirstResponder = true` を返す
  - `performKeyEquivalent(_:)` で Cmd+W を捕捉、`cancelOperation(_:)` で Esc を捕捉して `preview.close()` を呼ぶ
  - **フォーカス判定は「ラッパ自身が first responder」だけを見ない**: 内部の WKWebView / PDFView / NSImageView 等が first responder を持っていく可能性があるため、判定は「`keyWindow.firstResponder` がラッパ自身、またはラッパ配下の descendant（`isDescendant(of:)`）」にする。これでないと「プレビューにフォーカスしているはずなのに Esc/Cmd+W が効かない」事故が起きる
  - **ラッパや descendant が first responder でないときは false を返す**ことで responder chain に流す（→ Ghostty 側が Cmd+W を受ける）
- [ ] **フォーカスの渡し方も明示**: プレビューがマウントされた直後（`viewDidMoveToWindow` 等）と、プレビュー内クリック時に `window?.makeFirstResponder(wrapper)` を呼んでフォーカスを移す。ツリーからファイル選択でプレビューが開いたときも、自然にフォーカスがプレビュー側に渡るようにする
- [ ] **既存の `.keyboardShortcut(.escape)` を削除する**（NSResponder 経由に一本化）
- [ ] 現状の close ボタン（`FilePreviewView.swift:118`）と「←」「→」「🌲」のツールバーは維持

### Phase 6: 既存ショートカットの文言更新 [AI🤖]

4 カラム化でツリーは常駐になるため、Cmd+J の意味が「ツリー⇄プレビュー切替」から「プレビュー Show/Hide」に変わる。

- [ ] `ShortcutsStore.swift:15` の `.togglePreview` description を `"Toggle file tree / preview"` → `"Show/Hide Preview"`（or 同等の日本語/英語）に変更
- [ ] `.togglePreview` の発火先は active project の preview の close/open（既存 toggle ロジックがあれば流用）
- [ ] `docs/DEV.md` や README で Cmd+J を説明している箇所があれば追従

### Phase 7: テスト用フラグ [AI🤖]

- [ ] 起動時環境変数を 1 つ追加:
  - `POLEPOLE_TEST_SIDEBAR_COLLAPSED=1` → 起動時に `sidebarCollapsed = true`
- [ ] プレビュー開状態の再現は**既存 `POLEPOLE_TEST_AUTO_PREVIEW=<相対パス>` をそのまま再利用**（`ProjectsModel.swift:105-119` で既に実装済み、`docs/DEV.md:133` に記載済み）。新規フラグは作らない
- [ ] `docs/DEV.md` のフラグ一覧に `POLEPOLE_TEST_SIDEBAR_COLLAPSED` を追記

### 動作確認 [AI🤖]

- [ ] `mise run build` が通る（型・SwiftUI 警告含めて）
- [ ] テストフラグで 4 状態を起動して `polepole-screenshot.sh` で撮影:
  - サイドバー展開 × プレビュー閉
  - サイドバー展開 × プレビュー開
  - サイドバー折畳 × プレビュー閉（復帰ハンドル確認）
  - サイドバー折畳 × プレビュー開
- [ ] divider をドラッグして各ペインをリサイズ → アプリ再起動して幅が復元される
- [ ] プレビュー開いた状態で別プロジェクトに切替 → プレビュー状態が project ごとに独立しているか確認
- [ ] サイドバー復帰ハンドルをクリック → 展開できる
- [ ] プレビューにフォーカスがある状態で Cmd+W / Esc → プレビューが閉じる
- [ ] **プレビューが開いたまま、端末（Ghostty）にフォーカスして Esc / Cmd+W を押す → プレビューは閉じない**（フォーカスゲートが効いていることの直接確認 / 今回一番壊したくない挙動）
- [ ] プレビューが閉じている状態で Cmd+W → 従来通り Ghostty の terminal タブが閉じる
- [ ] サイドバー折畳ショートカット → toggle される
- [ ] サイドバー折畳中 + フルスクリーン / 最小幅で復帰ハンドルが見える位置にあり、左端 divider との hit testing 衝突がないか screenshot で確認
- [ ] Cmd+J（togglePreview）の Settings 画面表示が新ラベルに更新されている

### 動作確認 [人間👨‍💻]

- [ ] 普段の作業で 1 日使ってみて、ツリーが消える違和感が解消されているか体感
- [ ] サイドバー復帰ハンドルの幅 / 視認性が妥当か（細すぎてクリックしづらくないか、太すぎて邪魔ではないか）
- [ ] プレビューが開いた状態でターミナル側の文字幅が体感狭くなりすぎないか

### 完了後 [AI🤖]

- [ ] `docs/CHANGELOG.md` の `[Unreleased]` に ja/en 両方で追記
- [ ] `VERIFY.md` に「4 状態のスクリーンショット手順」を再利用可能な手順として追記

## ログ

### 試したこと・わかったこと

- 2026-05-25: Phase 1〜7 をワンパスで実装、`mise run build` 一発で通過（SourceKit 警告は全部偽陽性）
- 2026-05-25: 4 状態の screenshot 取得済み（`/tmp/v-layout-state{1,2,3,4}.png`）。すべて期待通り
  - State 1（サイドバー展開×プレビュー閉）: 3 カラム見える、プレビューは collapsed
  - State 2（サイドバー展開×プレビュー開）: 4 カラム、Markdown プレビュー表示
  - State 3（サイドバー折畳×プレビュー閉）: ファイルツリー + 復帰ハンドル `>` + ターミナル
  - State 4（サイドバー折畳×プレビュー開）: 復帰ハンドル + ツリー + プレビュー + ターミナル
- 復帰ハンドルの色: 当初 `Color.secondary.opacity(0.05)` だと暗背景で完全に消えた。`Color.accentColor.opacity(0.35)`（hovered で 0.85）に変更したら視認可能に
- 復帰ハンドル幅: 12pt → 14pt + 高さ 36pt → 44pt + `.padding(.leading, 2)` で divider との接触を回避

### 方針変更

- なし（レビュー指摘で前提を 5 件直したのが反映済み）

### 追加対応（実装中に判明）

- divider drag で auto-collapse したとき `sidebarCollapsed` / `activePreviewVisible` に sync されていなかった → `NSSplitViewItem.isCollapsed` を **KVO で観察** して双方向バインドを追加（`onSidebarCollapseDidChange` / `onPreviewCollapseDidChange`）。`updateNSViewController` 側の「現在値と異なるときだけ書く」ガードでループ回避
- Swift 6 strict concurrency 対応: KVO closure は @Sendable 推測なので `nonisolated(unsafe) let` で callback を opt-out + `Task { @MainActor }` で MainActor に hop
- サイドバートグルのデフォルトショートカット: 当初 Cmd+Shift+S にしたが、PolePole は編集機能を持たないので Cmd+S を空けて再割当（Settings 画面でリバインド可能）

### 動作確認結果（人間検証済み）

- 4 状態 screenshot 全部 OK（state1〜4）
- autosave 復元: 開閉状態どちらで終了しても再起動後に維持
- サイドバー divider drag で auto-collapse → 解放しても閉じたまま、復帰ハンドル出る、Ctrl+M で別 project に切替えてもサイドバー閉じたまま
- プレビュー drag close → 直後に別ファイルクリックの競合: 通常速度の操作では問題なし
