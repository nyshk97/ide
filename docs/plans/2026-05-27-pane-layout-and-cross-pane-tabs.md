# ペイン構成の柔軟化とタブのペイン間移動

## 概要・やりたいこと

右側シェルエリアの「上小・下大」の 2 ペイン固定だった構造を、プロジェクトごとに 1 ペイン / 2 ペインを切り替えられるように拡張する。あわせて「上下ペイン間でタブを移動する」操作（D&D + キーボードショートカット）を追加し、2 ペイン構成の使いこなしの幅を広げる。

### 背景・目的

- 「上下分割は要らない、1 ペイン派」のユーザーニーズがある（Claude しか使わないプロジェクト、画面が小さい環境、上下管理が面倒等）
- 同時に、Claude + Codex を並走させる典型ワークフローでは 2 ペインが要る
- プロジェクトごとに最適なレイアウトが違うので、グローバル設定では粒度が粗い
- 2 ペインモード時に「このタブは下でやるべきだった」と気付いたとき、shell を殺さずに移せるとセッションを失わず済む

---

## 前提・わかっていること

### コードベース現状

- **右側シェルエリアの分割**: `Sources/polepole/WorkspaceView.swift` の `SplitPane` (NSViewControllerRepresentable) + `RatioSplitViewController` が上下 2 ペインを 3:7 で配置。上ペインの `NSSplitViewItem.minimumThickness = 80`、下ペインは 200 (`WorkspaceView.swift:41,46`)
- **ペインのデータモデル**: `WorkspaceModel.topPane / bottomPane: PaneState`（プロジェクトごとに 1 インスタンス）。`activePane` でフォーカスを保持
- **タブのデータモデル**: `PaneState.tabs: [TerminalTab]` + `activeIndex`。タブは `PaneState` 配下に閉じている
- **WorkspaceModel のキャッシュ**: `ProjectsModel.workspaces: [UUID: WorkspaceModel]` で「一度開いたプロジェクト」の workspace が辞書に残る (`ProjectsModel.swift:23,25,287-290`)。**裏のプロジェクトの shell も生きている**設計
- **永続化先**: `Project` 値型の配列を `ProjectsStore.save(_ projects: [Project])` で `projects.json` に書く。`ProjectsModel.persist()` が `pinned + temporary` を渡す (`ProjectsModel.swift:818`)
- **既存ショートカット**: `Cmd+Opt+←/→` で同一ペイン内タブ切替、`Cmd+Opt+↑/↓` で上下ペイン間フォーカス移動（`MRUKeyMonitor.swift:94-113`）
- **closeTab の呼び出し元**: `TabsView.swift:141`（× ボタン）と `GhosttyTerminalView.swift:267-270`（`Cmd+W`）の 2 経路から `PaneState.closeTab/closeActiveTab` を直接呼ぶ。`PaneState.closeTab` 内で「最後の 1 個閉じたら自動 addTab」もやっている
- **既存 D&D**: `TabsView.swift` でタブの並び替えを実装済み。payload は `"paneID|tabID"` 形式で、`sourceTabID(from:)` は同一ペイン制限をかけて UUID 1 つだけ返す (`L21,33`)
- **FixedShortcuts**: `ShortcutsStore.swift:218-244` に固定ショートカットの一覧。設定画面の衝突警告の source なので、新規ショートカット追加時はここに足す必要がある
- **要件**: `REQUIREMENTS.md:38` で「右ペイン: 上小ターミナル + 下大ターミナル」が要件化されている

### Ghostty surface の所有権（ペイン間移動の鬼門）

- **`GhosttyTerminalNSView.surface` が Ghostty surface を strong 所有** (`L43`)
- **`NSView.deinit` で `ghostty_surface_free(s)` を呼ぶ** (`L73-78`) → NSView が破棄されれば PTY も死ぬ
- **`TerminalTab.nsView` は weak 参照のみ**（オーナーじゃなく逆引き用）
- `TabsView.swift:48` の `ZStack { ForEach(pane.tabs, id: \.element.id) }` で、上下ペインは別の ForEach コンテナ。SwiftUI は別コンテナ間で identity を引き継がない → 単純に `pane.tabs` 配列間で TerminalTab を動かすと、旧側で `dismantleNSView → deinit → surface_free`、新側で `makeNSView → createSurface` が走り、**shell が死ぬ**
- **`ghostty_surface_new` に nsview を作成時に Unmanaged で渡す方式**で、`ghostty_surface_set_*` には scale/focus/occlusion/size/color_scheme/display_id のみ。**nsview を後から差し替える C API は存在しない** (`GhosttyKit.xcframework/.../ghostty.h:1114-1189`) → surface だけを TerminalTab に移す案は不可

### Phase 2 の解決方針 (NSView を TerminalTab が抱え、SwiftUI には Container だけ見せる)

state-ful な NSView を SwiftUI の view tree 変動から保護する典型パターン（WKWebView を SwiftUI 内で生かす際にもよく使われる）。

```
TerminalTab (strong owner)
└─ realNSView: GhosttyTerminalNSView (Ghostty surface 所有)

SwiftUI tree:
GhosttyTerminalView (NSViewRepresentable)
  makeNSView()     → 空の Container NSView を返す
  updateNSView()   → container.addSubview(tab.realNSView) する
  dismantleNSView() → Container が消えるだけ。tab.realNSView は TerminalTab が保持しているので生存
```

**ポイント**:
- SwiftUI が壊せるのは Container だけ。Ghostty surface を持つ `tab.realNSView` は TerminalTab の strong 参照で守られる
- `container.addSubview(tab.realNSView)` は AppKit 仕様で**旧 superview から自動的に外す**。ペイン跨ぎで TerminalTab が別 ForEach に移っても、`tab.realNSView` の親付け替えで物理的に移動する。NSView 本体は一度も destroy されない → surface 生存 → shell 死なない
- `ghostty_surface_free` は **`TerminalTab.deinit` で呼ぶ**（NSView.deinit からは外す）

**surface 作成タイミング (現行と同じ遅延生成を維持)**:
- `ghostty_surface_new` は `cfg.platform.macos.nsview` に nsview pointer を渡す必要があり、現行実装も cmux 参考実装も **window attach 後** に surface を作っている。「window 無しでも作れる」前提は危険なので採らない
- 新設計でも surface 作成は `GhosttyTerminalNSView.viewDidMoveToWindow` 内（`window != nil && surface == nil` のとき）で行う = **現行と同じ遅延生成**
- 「裏で SwiftUI tree から外れても surface が生きる」効果は、**surface lifetime を TerminalTab に紐付ける**ことで達成できる（即時生成の有無とは独立）。tree から一時的に外れる → NSView は destroy されないので surface も生存 → 再 attach 時に既存 surface を使い続ける

### 確定した仕様

- **設定の粒度**: プロジェクトごと + 動的切替（`ProjectsStore` に永続化、`Cmd+Opt+\` でトグル）
- **1 ペイン化時の上タブ**: 裏に隠れて保持（α 案）。再分割で復活
- **自動遷移ルール**:
  - 上ペインのタブが 0 → `paneLayout = .singleBottom` に自動切替
  - 下ペインのタブが 0 → 新規タブ自動生成（今と同じ挙動）
- **1 ペインモードでの `Cmd+Opt+↑`**: 何もしない（明示切替は `Cmd+Opt+\` のみ）
- **1 ペインモード中の `Cmd+Shift+Opt+↑/↓`** (タブ移動): **no-op**（実装が楽な方）
- **ペイン collapse の手段**: `NSSplitViewItem.isCollapsed = true` を使う（`minimumThickness=80` を無視できるため）
- **永続化スキーマ**: `Project` 値型に `paneLayout` を追加。`init(from:)` では `decodeIfPresent` + `.split` フォールバックで旧 JSON 互換性を保つ

### 動作確認の前提

- Debug ビルドは Bundle ID `local.d0ne1s.polepole.dev` で `~/Library/Application Support/polepole-dev/` 配下にデータを書く → Brew 配布版 (`polepole/`) には触らない
- ペイン切替は `screencapture` で目視可、タブ移動・PTY 生存はキーストロークが要るので `polepole-keystroke.sh` が使える（PolePole 内 Claude Code から走らせる場合はユーザーに目視依頼）

---

## 実装計画

### Phase 1: 1 ペインモード [AI🤖]

ターゲット: プロジェクトごとに 1/2 ペインを切り替えられて、永続化される状態。surface 所有権リファクタは含まないので、1 ペイン化時は上ペインを `isCollapsed` で隠すだけ（上タブは裏で生存）。

#### 1-1. データモデル
- [x] `enum PaneLayout: String, Codable, Hashable { case split, singleBottom }` を **top-level** で定義（`Project.swift` の隣 or `WorkspaceModel.swift` の外側）。`Project.paneLayout` と `WorkspaceModel.paneLayout` の両方から参照できるようにする。`Project: Hashable` の stored property になるので `Hashable` も明示（String raw enum は自動合成されるが念のため）
- [x] `WorkspaceModel` に `@Published var paneLayout: PaneLayout` を追加（デフォルト `.split`）。`didSet` で `ProjectsModel.shared.updatePaneLayout(projectID: ...)` を呼ぶ
- [x] `WorkspaceModel.init(project:)` で `project.paneLayout` を初期値として受け取る

#### 1-2. 永続化（Project スキーマ拡張）
- [x] `Project` 値型に `var paneLayout: PaneLayout = .split` を追加
- [x] `Project.CodingKeys` に `paneLayout` を追加
- [x] `Project.init(from:)` は `decodeIfPresent(PaneLayout.self, forKey: .paneLayout) ?? .split` で旧 JSON 互換を保つ
- [x] `Project.encode(to:)` は **常に `encode`** で書く（`paneLayout` は非 optional なので `encodeIfPresent` だと「デフォルト値省略」にならない誤用になる。シンプルに常に書くで OK）
- [x] `ProjectsModel` に `updatePaneLayout(projectID: UUID, layout: PaneLayout)` を追加。`ProjectsModel.update(_:displayName:colorKey:)` (`ProjectsModel.swift:521-541`) と同じパターンで実装:
  1. apply closure を定義 (`p.paneLayout = layout`)
  2. `pinned` / `temporary` 配列の対応 index を見つけて apply
  3. `syncActive(to: <updated project>)` を呼んで activeProject と同期（対象が現在 active なら activeProject の paneLayout も更新される）
  4. `persist()` を呼ぶ

#### 1-3. ショートカット
- [x] `MRUKeyMonitor.swift` に `Cmd+Opt+\` (keyCode 42) のハンドラを追加。`activeWorkspace.paneLayout` をトグル
  - `.split → .singleBottom` への切替時、`activePane === topPane` だったら `activePane = bottomPane` に明示遷移
  - `.singleBottom → .split` への切替時、`activePane` は変更しない（暗黙に bottom のまま）
- [x] 既存の `Cmd+Opt+↑/↓` (フォーカス移動) を `paneLayout == .singleBottom` のとき no-op にする (`MRUKeyMonitor.swift:104-108`)
- [x] `ShortcutsStore.swift:225` の `FixedShortcuts.all` に `Cmd+Opt+\` (keyCode 42) を追加

#### 1-4. SplitPane の collapse 制御
- [x] `SplitPane` (`WorkspaceView.swift`) を `paneLayout` を観察するように変更
- [x] `paneLayout == .singleBottom` のとき、上ペインの `NSSplitViewItem.isCollapsed = true` に設定。`.split` のとき `false`
- [x] `RatioSplitViewController` の `updateNSViewController` 経路（または同等）で `paneLayout` の変化を `isCollapsed` に反映する
- [x] `isCollapsed` への切替アニメーションは `splitView.setPosition(...)` ではなく `splitViewItem.animator().isCollapsed = ...` で滑らかにする（任意。動かない場合は即値）

#### 1-5. closeTab 経路の責務移譲
- [x] `WorkspaceModel` に `closeTab(in pane: PaneState, at index: Int)` と `closeActiveTabOfActivePane()` を追加
- [x] 上記メソッドは以下を実行:
  1. `pane.tabs[index]` を remove（または closeActiveTab 相当）
  2. `pane.tabs.isEmpty` なら `handlePaneEmpty(pane)` を呼ぶ
  3. それ以外は activeIndex を整合
  4. **`ProjectsModel.shared.refreshUnreadProjects()` を呼ぶ**（既存 `PaneState.closeTab` から移植。未読タブを閉じた後のサイドバーリングが stale にならないように）
- [x] `WorkspaceModel.handlePaneEmpty(_ pane: PaneState)` を追加:
  - `pane === topPane && paneLayout == .split` →
    1. `paneLayout = .singleBottom` (上ペインの tabs は空のまま)
    2. **`activePane = bottomPane` に明示遷移**（hidden な topPane に Cmd+T / Cmd+W が効かないようにする）
  - それ以外（下ペイン or 1 ペイン中） → `pane.addTab()`
- [x] `PaneState.closeTab(at:)` から自動 addTab ロジック・`refreshUnreadProjects()` を削除（責務を WorkspaceModel に移す。`PaneState` 単体テストが将来出てきても困らない設計）
- [x] 呼び出し元の更新:
  - `TabsView.swift:141` `onClose: { self.pane.closeTab(at: index) }` → `workspace.closeTab(in: pane, at: index)`
  - `GhosttyTerminalView.swift:270` `activePane.closeActiveTab()` → `activeWorkspace.closeActiveTabOfActivePane()`
- [x] 上ペインが空のまま `.singleBottom` になった状態で再分割 (`Cmd+Opt+\`) を押したときの挙動を決める:
  - **方針**: 上ペインに空のタブを 1 つ作って分割表示する。`paneLayout = .split` トグル時に `topPane.tabs.isEmpty` なら `topPane.addTab()` を呼ぶ
  - これで「上ペインが空のまま split」になることはない

#### 1-6. ドキュメント
- [x] `REQUIREMENTS.md:38` を更新。「split がデフォルト、single もある（プロジェクトごとに永続化）」「`Cmd+Opt+\` で切替」と書き換え
- [x] `docs/CHANGELOG.md` の `[Unreleased]` に ja/en 1 bullet ずつ追記
- [x] `docs/ARCHITECTURE.md` の「キー入力の優先順位」セクションに `Cmd+Opt+\` を追記

### Phase 1 動作確認 [AI🤖 + 人間👨‍💻]

- [x] `mise run build` がエラーなく通る [AI🤖]
- [x] 古い `projects.json`（paneLayout が無い）を読み込んで全プロジェクトが復元されること [AI🤖 — 既存 polepole-dev/projects.json をバックアップ → 旧形式 fixture を投入 → 起動 → サイドバーにプロジェクト一覧が出ることを確認]
- [x] `./scripts/polepole-launch.sh` + `./scripts/polepole-screenshot.sh` で初期状態が 2 ペインなことを目視 [AI🤖]
- [x] `Cmd+Opt+\` 押下後に 1 ペインになる、再度押下で 2 ペインに戻ることを確認 [人間👨‍💻 — keystroke + 目視]
- [x] 2 ペイン中、上ペインの全タブを × ボタンで閉じると自動で 1 ペインモードに遷移することを確認 [人間👨‍💻]
- [x] 2 ペイン中、上ペインで `Cmd+W` を連打して全タブを閉じても自動で 1 ペインモードに遷移することを確認 [人間👨‍💻]
- [x] 1 ペイン中の最後のタブを閉じると新規タブが自動生成されることを確認 [人間👨‍💻]
- [x] 1 ペイン中に `Cmd+Opt+↑/↓` が no-op であることを確認（フォーカスが暴れない） [人間👨‍💻]
- [x] プロジェクト切替で `paneLayout` がプロジェクトごとに保持されることを確認 [人間👨‍💻]
- [x] PolePole を完全終了 → 再起動して `paneLayout` が復元されることを確認 [人間👨‍💻]
- [x] 設定画面（Shortcuts settings）で `Cmd+Opt+\` を他のショートカットに割り当てようとしたとき衝突警告が出ること [人間👨‍💻]

### Phase 2 着手前の準備 [人間👨‍💻]

- [ ] Phase 1 を一度コミットしておく（Phase 2 が詰まったとき Phase 1 だけはリリースできる状態にする）

### Phase 2: NSView ごと TerminalTab が所有するリファクタ [AI🤖]

ターゲット: SwiftUI の view tree 変動と無関係に Ghostty surface を生かしておけるようにする。Phase 3 のペイン間タブ移動の前提。

#### 2-1. TerminalTab に NSView を持たせる
- [x] `TerminalTab` に `let realNSView: GhosttyTerminalNSView` を追加（strong）
- [x] `TerminalTab.init` で `GhosttyTerminalNSView` を生成し `realNSView` に代入。さらに `realNSView.tab = self` で逆参照を張る
- [x] `TerminalTab.deinit` で `realNSView` の surface を解放（後述 2-3 の手順で）
- [x] 既存の `weak var nsView: NSView?` は撤去（`realNSView` に一本化）。逆引き用途は `tab.realNSView` で直接見られる
- [x] 関連箇所の `tab.nsView` 参照を `tab.realNSView` に置換: `WorkspaceModel.focusPane()` (`L41-52`)、その他あれば全て

#### 2-2. SwiftUI ラッパを Container 方式に書き換え
- [x] `GhosttyTerminalView` (`GhosttyTerminalView.swift:7`) を以下のように書き換え:
  - `makeNSView` は空の `NSView` (Container) を返す（フレーム指定なし）
  - `updateNSView` で:
    - もし `tab.realNSView.superview !== container` なら `container.addSubview(tab.realNSView)` を呼ぶ（AppKit が旧 superview から自動で外す）
    - **`tab.realNSView.pane = pane` を毎回更新**（updateNSView は SwiftUI の pane 引数を毎回受け取るので、ペイン間移動後に古い pane weak 参照が残らないようここで張り替える。これを忘れると `becomeFirstResponder` が wrong pane を active にする）
    - `tab.realNSView` を Container と同サイズに張る（Auto Layout または `autoresizingMask = [.width, .height]` + `frame = container.bounds`）
  - `dismantleNSView` は no-op（あるいは `tab.realNSView` が container.subviews に居れば removeFromSuperview だけ）。surface は触らない

#### 2-3. surface ライフサイクルの移譲
- [x] `GhosttyTerminalNSView.deinit` から `GhosttyManager.shared.unregister(surface:)` と `ghostty_surface_free(s)` を削除
- [x] 代わりに `GhosttyTerminalNSView` にインスタンスメソッド `func releaseSurface()` を追加し、以下を実行:
  1. `unregister` + `ghostty_surface_free` + `surface = nil`
  2. **`lastPixelWidth = 0; lastPixelHeight = 0` でサイズキャッシュをリセット**（次の `createSurface()` で新 surface に初回 size を確実に送るため。`syncSize()` (`L217-230`) は同 pixel size だと早期 return するので、キャッシュが残ったままだと新 surface に size が送られない）
- [x] `GhosttyTerminalNSView` に **`func restartSurface()`** を追加。`releaseSurface()` を呼んでから `createSurface()` を呼ぶ（`createSurface()` の private を維持し、外部からは `restartSurface()` を通すことで lifecycle 周りの逸脱を防ぐ）
- [x] `TerminalTab.deinit` で `realNSView.releaseSurface()` を呼ぶ（@MainActor 制約注意。`MainActor.assumeIsolated` などで対応）
- [x] `GhosttyTerminalNSView.viewDidMoveToWindow` のロジックは現状の `if window != nil, surface == nil { createSurface() }` のまま維持（遅延生成方針）

#### 2-4. surface 作成タイミング (現行と同じ遅延生成を維持)
- [x] `GhosttyTerminalNSView.viewDidMoveToWindow` の `if window != nil, surface == nil { createSurface() }` ロジックは現状通り残す。`ghostty_surface_new` が `cfg.platform.macos.nsview` を要求するため、windowless で作る方式は採らない
- [x] 新設計でも「裏で SwiftUI tree から外れる」と Container は dismantle されるが、`tab.realNSView` は TerminalTab に掴まれて生存し続けるので、surface も生きたまま。再 attach 時は `viewDidMoveToWindow` の condition `surface == nil` に該当しないので createSurface は走らず、既存 surface を使い続ける
- [x] window が付くタイミングで `ghostty_surface_set_display_id`、`ghostty_surface_set_content_scale` を呼ぶフローは現状通り (`L207-211`)

#### 2-5. restart() 経路の検証
- [x] `TerminalTab.restart()` (`TerminalTab.swift:54-57`) は現状 `lifecycle = .alive; generation += 1` で SwiftUI の `.id` を変えて view 再生成する。新設計では view 再生成しても `realNSView` は同じインスタンス → surface も同じ → restart にならない
- [x] **新しい restart の実装**:
  1. `realNSView.restartSurface()` を呼ぶ（2-3 で追加した `releaseSurface()` + `createSurface()` 一体メソッド。サイズキャッシュリセットも内包される）
  2. **`lifecycle = .alive` を必ず戻す**（ExitedOverlayView の表示条件 `if case .exited = tab.lifecycle` が満たされたままだと overlay が消えないので必須）
  3. `generation += 1` は不要（SwiftUI 経由の view 再生成は不要になる）
- [x] `ExitedOverlayView` の `onRestart: { tab.restart() }` 経路がそのまま動くことを確認（overlay 消える + 新しい shell が立ち上がる）

### Phase 2 動作確認 [AI🤖 + 人間👨‍💻]

- [x] `mise run build` が通る [AI🤖]
- [x] 起動後にシェルが正常に立ち上がること、PTY 入出力が動くこと [AI🤖 — keystroke + screenshot]
- [x] タブ切替で旧タブの surface が解放されないこと（裏に隠れたタブの shell プロセスが生きていることを `ps -ef | grep -E "(zsh|bash)"` で確認） [AI🤖]
- [x] タブを × ボタンで閉じると surface が解放されること（対応 shell プロセスが消える） [AI🤖]
- [x] `Cmd+W` で閉じても同様に shell プロセスが消えること [AI🤖]
- [x] `restart()` 経路（exit overlay の「再起動」ボタン）が動くこと [人間👨‍💻]
- [x] `Cmd+Opt+\` での 1↔2 ペイン切替で上ペインのタブの shell が生存し続けること [人間👨‍💻]
- [x] プロジェクト切替で裏に回ったプロジェクトの shell が生存していること [人間👨‍💻]
- [x] Phase 1 で確認した全項目が引き続きパスすること [人間👨‍💻]
- [x] PolePole 終了時に全 shell プロセスが綺麗に解放されること（プロセスリーク無し） [AI🤖]

### Phase 3: タブのペイン間移動 [AI🤖]

> ⚠️ **2026-05-27 時点で着手保留 (新方針で再設計済み、実装は後日)**: 当初 Container 方式 (`addSubview` で realNSView を別 superview に reparent) で実装したが、移動後の Ghostty surface のレンダリングが新階層に追従しないバグで撤退。原因は **libghostty が surface 作成時の NSView pointer / CAMetalLayer を内部で握り続けるため、AppKit 側で reparent しても layer / display link が新階層に再束縛されない**こと。cmux 実装も同様の理解で、reparent ではなく **portal host + anchor 追従**方式を採用している。詳細は本ファイル下部「ログ > 試したこと・わかったこと」「ログ > 方針変更」を参照。

ターゲット: D&D とキーボードショートカットで上下ペイン間にタブを移動できる状態。**`realNSView` は一度 host に attach したら以降 reparent しない**設計。

#### 3-0. 新方針 (anchor + portal host 方式)

```
NSWindow
├─ TerminalsHostView (= portal host、window root 直下に 1 個固定)
│   ├─ tab1.realNSView (frame は anchor1 を window 座標に変換した値)
│   ├─ tab2.realNSView (frame は anchor2…、非 active なら isHidden=true)
│   └─ tab3.realNSView (...)
│
└─ SwiftUI tree
    ├─ 上ペインの TabsView
    │   ├─ pane clip slot (NSView, host の subview を frame で位置決め)
    │   └─ TerminalAnchorView(tab=tab1)  ← layout で frame を WorkspaceModel に伝える
    └─ 下ペインの TabsView
        ├─ pane clip slot
        └─ TerminalAnchorView(tab=tab2)
```

**ポイント**:
- `realNSView` は一度 `TerminalsHostView` に `addSubview` したら以降 **reparent しない**。Metal binding が壊れない
- 各 SwiftUI tab content には軽量な `TerminalAnchorView` (NSViewRepresentable で `NSView` を返すだけ) を置き、その frame を window 座標に変換して `WorkspaceModel.terminalGeometry[tabID]` に書き込む
- レイアウトが落ち着いた tick で `TerminalsHostView` が `tab.realNSView.frame` を anchor 位置に合わせる (geometry reconcile)
- タブ移動 = `tabs` 配列間で `TerminalTab` を移すだけ。`realNSView` の親は変わらず、`anchor` 位置 (上ペインの slot → 下ペインの slot) が変わるので frame が追従して見た目が移動する
- 非 active タブは `isHidden = true` か frame をオフスクリーン (`-10000, -10000`) に
- pane 境界で clip: pane 配下に slot view (`wantsLayer = true`, `masksToBounds = true`) を仕込んで、host の subview をその上に重ねる。slot は SwiftUI から AppKit のクリッピング容器として使う
- focus: タブ切替やペイン跨ぎ移動のとき `makeFirstResponder(tab.realNSView)` を呼ぶ。`realNSView.pane` は新ペインに張り替えてから

#### 3-1. PoC: 1 タブを host + anchor で動かす
- [x] `TerminalsHostView` (NSView サブクラス、`wantsLayer = true`) を作成し、`WorkspaceView` のルートに 1 個だけ配置
- [x] `TerminalAnchorView` (`NSViewRepresentable`) を作成。空の NSView を返し、`layout` 通知で自身の `convert(bounds, to: window.contentView)` を `WorkspaceModel.setAnchor(for: tabID, frame:)` で公開
- [x] `WorkspaceModel.terminalGeometry: [UUID: CGRect]` を `@Published` で持つ。または observer で TerminalsHostView に流す
- [x] `TerminalsHostView.reconcileGeometry()` を実装。各 tab の `realNSView.frame` を anchor frame に合わせる。`isHidden` も active かどうかで切替
- [x] 既存の `GhosttyTerminalView` (Container 方式) を撤去。`TabsView` の中身は `TerminalAnchorView(tab:)` に変える
- [x] PoC 段階: 1 ペイン構成でタブ切替が壊れないことを確認 (描画追従、focus、IME、resize)

#### 3-2. ペイン境界の clip 対応
- [x] 各 `TabsView` の content area に `PaneClipSlotView` (NSView, `masksToBounds = true`) を仕込み、TerminalsHostView の subview がはみ出ないようにする
- [x] あるいは、各 pane の bounds で realNSView の `mask` layer を切る方法も検討
- [x] ペイン divider のドラッグ resize 中も追従すること

#### 3-3. moveTab API (Phase 2 で書いた版を簡素化)
- [x] `WorkspaceModel.moveTab(_ tabID: UUID, from sourcePane: PaneState, to targetPane: PaneState, before beforeTabID: UUID?)`:
  - sourcePane.tabs から remove → targetPane.tabs に insert
  - `activePane = targetPane`、target の activeIndex を insert 位置に
  - **`tab.realNSView.pane = targetPane` を張り替え** (becomeFirstResponder で wrong pane を active にしないため)
  - `window.makeFirstResponder(tab.realNSView)`
  - sourcePane が空なら `handlePaneEmpty(sourcePane)` (Phase 1 実装済み)
  - **realNSView の reparent は不要**: 次の layout で anchor が新ペインに移ったことが反映されて frame が追従する

#### 3-4. D&D の cross-pane 対応
- [x] `TabsView.swift` の `sourceTabID(from:)` を `sourceTabRef(from:) -> (paneID: UUID, tabID: UUID)?` に変更
- [x] dropDestination: 同一ペイン → `pane.moveTab`、別ペイン → `workspace.moveTab`

#### 3-5. キーボードショートカット
- [x] `MRUKeyMonitor` に `Cmd+Shift+Opt+↑/↓` ハンドラ追加 (1 ペイン中は no-op)
- [x] `FixedShortcuts.all` に追加

#### 3-6. ドキュメント
- [x] `docs/CHANGELOG.md` `[Unreleased]` に追記
- [x] `docs/ARCHITECTURE.md` の「キー入力の優先順位」と「全体図」セクションを更新 (TerminalsHostView の位置付け)

### Phase 3 動作確認 [AI🤖 + 人間👨‍💻]

- [x] `mise run build` が通る [AI🤖]
- [x] **3-1 PoC 段階**: 1 ペイン構成でタブ切替が壊れないこと (描画、focus、IME) [人間👨‍💻]
- [x] D&D で上ペインのタブを下ペインに移動 → 描画が新位置に追従、Claude セッション継続 [人間👨‍💻]
- [x] D&D で下ペインのタブを上ペインに移動 [人間👨‍💻]
- [x] `Cmd+Shift+Opt+↓` / `↑` でタブが移動 [人間👨‍💻]
- [x] 上ペインの最後のタブを下に移動 → 自動で 1 ペインモードに [人間👨‍💻]
- [x] 1 ペインモード中の `Cmd+Shift+Opt+↑/↓` が no-op [人間👨‍💻]
- [x] ペイン divider をドラッグ resize しても realNSView が anchor に追従 [人間👨‍💻]
- [x] ペイン境界で realNSView が clip される (はみ出ない) [人間👨‍💻]
- [x] Phase 1/2 で確認した全項目が引き続きパス [人間👨‍💻]

### 仕上げ [AI🤖 + 人間👨‍💻]

- [ ] `VERIFY.md` に再現性のある確認手順を追記（既存の構造・粒度に合わせる） [AI🤖]
- [ ] `/retro` で振り返り [人間👨‍💻]

---

## ログ

### 試したこと・わかったこと

- **2026-05-27 衝突警告のバグ発見**: 動作確認で `Cmd+Opt+\`（後に `Cmd+/`）を Settings で他に割り当てようとしたら、衝突警告が出ず裏で実動作してしまった。原因は `MRUKeyMonitor` の `NSEvent.addLocalMonitorForEvents` がプロセスレベルで keyDown を握り、`ShortcutsSettingsView` の録音 monitor より先勝ちで消費していたため。これは Cmd+P / Cmd+Shift+F 等の既存固定ショートカットでも同じ問題があった既知の穴。`ShortcutsStore.isRecordingShortcut: Bool` を追加し、録音中は MRUKeyMonitor 側で素通り (`return false`) させて解決。Phase 1 の付随修正として取り込み

- **2026-05-27 isCollapsed が初期 setPosition に上書きされる問題**: 起動時に `paneLayout = .singleBottom` のはずなのに 2 ペインで開いた。原因は `RatioSplitViewController.viewDidLayout` の初回 `setPosition(h * initialTopRatio, ofDividerAt: 0)` が、`makeNSViewController` で立てた `topItem.isCollapsed = true` を上書きしていた。`makeNSViewController` で `paneLayout == .singleBottom` のときに `svc.didSetInitial = true` を予め立てて、初回 `setPosition` を抑止して解決

- **2026-05-27 Phase 2 Container 方式リファクタ完了**: 設計通り動いた。`TerminalTab.realNSView`（strong）+ Container NSView の二段構成で、SwiftUI tree の dismantle / make を受けても surface が生存。動作確認:
  - 起動後の子プロセス数: `/usr/bin/login × 2`（上下ペイン分）
  - スクリーンショットで両ペインに shell prompt 表示
  - 人間確認: Cmd+/ で 1↔2 ペイン切替しても上タブの shell が生存（Phase 2 の本丸）
  - `TabsView` の `.id("\(tab.id)-\(tab.generation)")` を `.id(tab.id)` に simplify、`TerminalTab.generation` property を撤去（Container 方式で view 再生成不要のため）
  - `tab.nsView` (weak) → `tab.realNSView` (strong) に一本化

### 方針変更

- **2026-05-27 ペインレイアウト切替ショートカット**: 当初 `Cmd+Opt+\` だったが、ユーザー要望で `Cmd+/` に変更。さらに「設定で変えられるようにして」との要望で `ShortcutAction.togglePaneLayout` としてリバインド可能化（defaults: `Cmd+/`）。これに伴い `FixedShortcuts.all` の entry は不要となり削除。TabsView の help テキストも `ShortcutsStore.shared.combo(for: .togglePaneLayout).display` で動的に組み立てる形に変更（リバインド時に自動追従）

- **2026-05-27 下ペインのトグルボタンを常時表示に変更**: 当初は「1 ペインモード時のみ分割追加ボタンを表示」予定だったが、UI 統一感のためトグルボタンとして常時表示に変更。`.split` 時は `rectangle.bottomhalf.filled`（上を畳むイメージ）、`.singleBottom` 時は `rectangle.split.1x2`（分割追加イメージ）で同じ位置のアイコンが切替わる。下ペイン = メイン作業領域の前提と整合

- **2026-05-27 Phase 3 を一旦 revert**: Phase 3 の moveTab / D&D cross-pane / `Cmd+Shift+Opt+↑/↓` を実装し、機能としては動作（タブが物理的にペイン間を移動、shell プロセスも生存）。ただし**移動後に Ghostty surface のレンダリングが新 superlayer に追従しない**バグに遭遇し、新タブ側が真っ黒のままになる。試したこと:
  - `lastPixelWidth/Height = 0` で size キャッシュリセット + `syncSize()` 再実行 → 効かず
  - `ghostty_surface_refresh()` で強制再描画 → 効かず
  - `ghostty_surface_set_occlusion(false)` 追加 + `Task { @MainActor }` で 1 tick 遅延の再 invalidate → 起動シーケンス自体を壊した（全タブで prompt が出なくなる）ため即 revert
  CAMetalLayer の `addSubview` 後の再 attach 周りで、Ghostty 内部の render 経路を読まずに推測ベースで触ると危険と判断。Phase 3 関連の uncommitted な変更（5 files）を `git checkout --` で破棄し、Phase 2 状態に戻した。**ペイン間タブ移動は将来の調査タスクとして残す**（Ghostty / cmux 実装の研究が必要）

- **2026-05-27 (リリース後) Phase 3 を anchor + portal host 方式で実装、動作**: 外部調査の方針通り `TerminalsHostView` (portal host) + `TerminalAnchorView` (`AnchorNSView`) + WorkspaceModel.moveTab で実装したところ、ペイン跨ぎ移動後も Ghostty surface の描画と shell セッションが継続することを確認。設計上の細かいハマりどころ:
  - `host` を `ZStack` 上層に重ねたとき `host.hitTest` を「subview のエリア内なら subview、外は nil」で SwiftUI 階層に event を通す必要がある (実装済)
  - `TerminalAnchorView.updateNSView` で `tab.realNSView.pane = pane` を毎回張り替えないと、ペイン跨ぎ移動後に `becomeFirstResponder` が旧 pane を `setActive` してしまい、マウスクリック / `Cmd+Opt+↑/↓` でフォーカスが移らない症状になる
  - `Cmd+/` で 1 ペインモードに切替た瞬間、`topPane` 配下の anchor view が「collapsed transition 中の古い frame」を通知し、`realNSView` が画面上方に居座って「上ペインの shell が見えている」状態になる。`TerminalAnchorView` の `isActive` 判定に「pane が表示中か」(`workspace.paneLayout == .split || pane === bottomPane`) を含めて、裏ペインを host 側で強制オフスクリーン化することで解決

- **2026-05-27 (リリース後) コードレビュー指摘 5 件を反映**:
  1. `WorkspaceModel.closeTab` で `terminalsHost.detach(realNSView)` + `releaseSurface()` を即時実行 (host が subview を強参照し続けるため、これをしないと閉じたタブの view が画面に残り続け、`TerminalTab.deinit` も遅延する)
  2. `TerminalsHostView.hitTest` の座標変換を修正 (`point` は `superview` 座標系なので、`self` 座標に変換してから subview の frame と比較、subview への `hitTest` には変換後の self 座標を渡す)
  3. `closeTab` で閉じたタブが active だった場合に新 active tab に `makeFirstResponder` を移す (firstResponder 残留対策)
  4. `AnchorNSView.viewDidMoveToSuperview` で `notifyHostNow` を発火 (reparent 経由で `viewDidMoveToWindow` が走らないケース対策)
  5. `paneIsVisible` で 1 ペインモード時の `topPane` の anchor を inactive 扱いに

- **2026-05-27 (リリース後) 外部調査結果: reparent 方式は塞がれている**: cmux のソースを実際に読んでもらったところ、Container 方式 (`addSubview` で reparent) はそもそも libghostty + Metal の仕組み上動かないことが判明:
  - `ghostty_surface_new` 時に `cfg.platform.macos.nsview = self` で渡した NSView pointer / CAMetalLayer / display link を **libghostty が内部で握り続けている**。`ghostty_surface_set_*` には nsview 差し替え API がなく、新 superlayer への再束縛もできない (`GhosttyTerminalView.swift:194` 参照)
  - cmux の `TerminalSurface.attachToView` も「既に別 view に attach 済みなら skip」する作りで、reparent 経路は最初から塞がれている (`.refs/cmux/Sources/GhosttyTerminalView.swift:4740` 参照)
  - cmux は代わりに **portal host / lease / geometry reconcile** で「見た目上の配置を動かす」方式を採用。ソースに「別 pane に mount されたら portal host lease を置き換える」「待つと moved pane が blank/stale になる」のコメントがあり、今回の症状と一致
  → 新方針: `realNSView` は window root 直下の `TerminalsHostView` に一度だけ attach、各 SwiftUI tab content は軽量な `TerminalAnchorView` だけ置いて anchor frame を host に伝え、host が `realNSView.frame` を追従させる。タブ移動は `realNSView` の reparent ではなく「どの anchor に追従するか」を切り替えるだけ。Phase 3 セクションをこの方針で書き直し済み。再着手は別タイミング
