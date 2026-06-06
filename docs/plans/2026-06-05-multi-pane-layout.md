# マルチペインレイアウト拡張

## 概要・やりたいこと

タブバー右端にあるレイアウト切替ボタンを拡張する。  
現状は「上下 2 分割 ↔ 1 ペイン」のトグル 1 個だけ。これを以下 4 パターンに対応したボタン群に置き換える。

| ボタン | レイアウト | SF Symbol（要実機確認）|
|---|---|---|
| 1 ペイン | `.singleBottom` | `rectangle` |
| 上下 2 分割 | `.split` | `rectangle.split.1x2`（現行と同じ） |
| 左右 2 分割 | `.splitHorizontal` | `rectangle.split.2x1` |
| 2×2 グリッド | `.splitFour` | `square.grid.2x2` |

> **注意**: `rectangle.split.1x2`（1 wide × 2 tall）が上下、`rectangle.split.2x1`（2 wide × 1 tall）が左右。  
> 現行コード `TabsView.swift:147` がすでに `1x2` を上下分割のヒントアイコンに使っているのに合わせる。  
> 実機で見た目を確認して違和感があれば差し替える。

## 前提・わかっていること

### アーキテクチャ
- `PaneLayout` enum は `Project.swift` で定義（`Codable` / `String` rawValue）
- `WorkspaceModel` が `topPane` / `bottomPane` を持ち、`paneLayout` で表示を切り替える
- `WorkspaceView` の `SplitPane`（`NSViewControllerRepresentable`）が `NSSplitViewController` をラップ。現在 `isVertical = false`（上下）固定
- `TabsView` の `bottomPane` タブバーに既存トグルボタン 1 個がある
- portal host 方式：`tab.realNSView` は `terminalsHost`（ZStack 最上層）に固定 attach。`TerminalAnchorView` が anchor frame を host に通知して `realNSView.frame` を追従させる

### ペインのマッピング

| レイアウト | topPane | bottomPane | topRightPane | bottomRightPane |
|---|---|---|---|---|
| `.singleBottom` | 非表示（collapsed） | 表示（メイン）| 非表示 | 非表示 |
| `.split` | 上（小） | 下（大）| 非表示 | 非表示 |
| `.splitHorizontal` | 左 | 右 | 非表示 | 非表示 |
| `.splitFour` | 左上 | 左下 | 右上 | 右下 |

### キーボードショートカット

`togglePaneLayout` を廃止し、レイアウト 1 つにつき 1 つの `ShortcutAction` に分離する。

| ShortcutAction（新規）| レイアウト | デフォルトキー | keyCode |
|---|---|---|---|
| `setPaneLayoutSingle` | `.singleBottom` | Cmd+Opt+1 | 18 |
| `setPaneLayoutSplit` | `.split` | Cmd+Opt+2 | 19 |
| `setPaneLayoutHorizontal` | `.splitHorizontal` | Cmd+Opt+3 | 20 |
| `setPaneLayoutFour` | `.splitFour` | Cmd+Opt+4 | 21 |

- `ShortcutsStore.swift`: `togglePaneLayout` action を削除し、上記 4 action を追加。modifiers は `[.command, .option]`
- `MRUKeyMonitor.swift`: `togglePaneLayout` の呼び出しを各 action に差し替え
- 既存の `WorkspaceModel.togglePaneLayout()` は不要になるため削除

#### `Cmd+Opt+↑/↓` / `Cmd+Shift+Opt+↑/↓` の guard 更新

現状は `ws.paneLayout == .split` の guard がある（`MRUKeyMonitor.swift:112, 135`）。  
この guard を **`ws.paneLayout != .singleBottom && (ws.activePane === ws.topPane || ws.activePane === ws.bottomPane)`** に変更する。  
- `.singleBottom` では topPane が hidden なのでショートカットを無効化
- 右列（`topRightPane` / `bottomRightPane`）にフォーカスがある場合も無効化（左列への誤移動を防ぐ）  
- 右列ペイン間のフォーカス移動は今回スコープ外

### オフスクリーン退避の一般化

`AnchorNSView.notifyHostNow()` は `window == nil` のとき skip するため、AnchorView がアンマウントされると `realNSView` が最後の位置に留まる。  
**対策**: `setPaneLayout` の先頭で「新レイアウトで非表示になるペインのアクティブタブ」を全件オフスクリーン退避してから `paneLayout = layout` を実行する。  
非アクティブタブは `TerminalAnchorView.isActive == false` の時点で `setGeometry` が既に (-10000, -10000) にセットしているため退避不要。

| 遷移 | 退避すべきペイン |
|---|---|
| → `.singleBottom` | topPane ＋ topRightPane / bottomRightPane のアクティブタブ |
| → `.split` / `.splitHorizontal` | topRightPane / bottomRightPane のアクティブタブ |
| → `.splitFour` | なし（新規 AnchorView が mount されて上書きされる） |

`.singleBottom` 時の topPane は collapsed NSSplitViewItem として AnchorView が残るため理論上は不要だが、view tree 全置換を伴う splitFour → singleBottom 遷移で topPane も一時アンマウントされる経路があるため退避対象に含める。

### `handlePaneEmpty` 仕様（各ペイン × レイアウト）

| ペイン | レイアウト | 挙動 |
|---|---|---|
| topPane | `.split` | → `.singleBottom`（既存動作） |
| topPane | `.splitHorizontal` | → `.singleBottom`（左ペインが消えたら 1 ペインに降格） |
| それ以外 | すべて | 新規タブを 1 つ自動生成（降格なし） |

`.splitFour` で右列ペインが空になっても自動的に `.split` へは降格しない。タブを補充するだけ。

### `setPaneLayout` の activePane 補正

レイアウト変更後に `activePane` が非表示ペインのままだとキー操作（`Cmd+T` / `Cmd+W` 等）が見えないペインへ届き、AppKit の firstResponder が非表示 `realNSView` に残り続けるリグレッションになる。

```
visiblePanes(layout):
  .singleBottom → [bottomPane]
  .split / .splitHorizontal → [topPane, bottomPane]
  .splitFour → [topPane, bottomPane, topRightPane, bottomRightPane]
```

`setPaneLayout` の末尾で `activePane ∉ visiblePanes(newLayout)` なら `focusPane(bottomPane)` を呼ぶ。  
（`activePane = bottomPane` だけでは AppKit firstResponder が旧ペインの `realNSView` に残るため、`focusPane` 経由で `makeFirstResponder` まで実施する。）

### `paneLayout` へのアクセス制御

`paneLayout` は `private(set)` にして外部からの直接代入を禁止する。  
`togglePaneLayout` / `handlePaneEmpty` / layout ボタンはすべて `setPaneLayout` 経由のみとする。  
これにより、オフスクリーン退避と activePane 補正の bypass 経路を排除する。

### SplitPane の isVertical 更新問題

`.split`（isVertical=false）と `.splitHorizontal`（isVertical=true）はどちらも `SplitPane<TabsView, TabsView>` を返す。SwiftUI が型一致で in-place 更新すると `makeNSViewController` が呼ばれず、`isVertical` が変わらない（`WorkspaceView.swift:52` 参照）。

**対策**: `SplitPane` に `.id(isVertical)` を付与する。`isVertical` が変わったとき SwiftUI が旧 VC を dismantle して新 VC を作り直す。  
`.singleBottom` ↔ `.split` 間は `isVertical` が同じ（どちらも `false`）なので既存の `isCollapsed` アニメーションが引き続き使われる。

### 初期分割比率

| レイアウト | 外側比率 | 内側比率 |
|---|---|---|
| `.split` | — | 上: 0.3 / 下: 0.7（既存） |
| `.splitHorizontal` | — | 左: 0.5 / 右: 0.5 |
| `.splitFour` | 左列: 0.5 / 右列: 0.5 | 各列上: 0.5 / 下: 0.5 |

`RatioSplitViewController` の `viewDidLayout` は `splitView.isVertical` を見て `bounds.width` or `bounds.height` を使い分ける。

### `paneIsVisible`（TabsView）

`paneIsVisible` は `visiblePanes(layout)` と同じロジックで判定する。「`.singleBottom` 以外は全部 true」にすると `.split` / `.splitHorizontal` 遷移中に topRightPane/bottomRightPane が visible 扱いされる余地があるため。

```swift
private var paneIsVisible: Bool {
    switch workspace.paneLayout {
    case .singleBottom:  return pane === workspace.bottomPane
    case .split, .splitHorizontal:  return pane === workspace.topPane || pane === workspace.bottomPane
    case .splitFour:  return true
    }
}
```

### 変更ファイル

1. `Sources/polepole/Project.swift` — `PaneLayout` enum に 2 case 追加
2. `Sources/polepole/WorkspaceModel.swift` — 追加 2 ペイン・`paneLayout` を `private(set)` 化・`setPaneLayout` 追加・`togglePaneLayout` 廃止
3. `Sources/polepole/WorkspaceView.swift` — `SplitPane` を `isVertical` / `isCollapsed` パラメータ化・`.id(isVertical)` 付与・4 レイアウト対応
4. `Sources/polepole/TabsView.swift` — 4 ボタン化・`paneByID` 更新・`paneIsVisible` 更新
5. `Sources/polepole/MRUKeyMonitor.swift` — `focusPane` / `moveTab` の guard を `paneLayout != .singleBottom && (activePane is top/bottom)` に更新、`togglePaneLayout` call を 4 action に差し替え
6. `Sources/polepole/ShortcutsStore.swift` — `togglePaneLayout` を削除し `setPaneLayoutSingle/Split/Horizontal/Four` 4 action を追加

---

## 実装計画

### Phase 1: データモデル [AI🤖]

- [x] `Project.swift`: `PaneLayout` に `.splitHorizontal` と `.splitFour` を追加
- [x] `WorkspaceModel.swift`:
  - [x] `topRightPane: PaneState` と `bottomRightPane: PaneState` プロパティを追加
  - [x] `allPanes: [PaneState]` computed property を追加
  - [x] `init` で追加 2 ペインを初期化
  - [x] `paneLayout` を `private(set)` にする
  - [x] `setPaneLayout(_ layout: PaneLayout)` を実装
    - 先頭でオフスクリーン退避（前提セクションのテーブル参照）
    - 各 case で必要なペインのタブ補充
    - 末尾で `activePane ∉ visiblePanes(newLayout)` なら `focusPane(bottomPane)` を呼ぶ
  - [x] `togglePaneLayout()` を削除（ShortcutAction の個別 action に置き換えるため不要）
  - [x] `handlePaneEmpty` に `.splitHorizontal` / `.splitFour` の分岐を追加（仕様テーブル参照）、`setPaneLayout` 経由に統一
  - [x] `hasUnreadTab` を `allPanes` ベースに更新

### Phase 2: ビュー層（WorkspaceView） [AI🤖]

- [x] `SplitPane` のシグネチャ変更: `paneLayout: PaneLayout` → `isVertical: Bool`, `isCollapsed: Bool`
- [x] `SplitPane` に `.id(isVertical)` を付与（`.split` ↔ `.splitHorizontal` で VC を作り直す）
- [x] `RatioSplitViewController.viewDidLayout` を `isVertical` 対応（`bounds.width` / `bounds.height` を動的に選択）
- [x] `WorkspaceView.body` を `twoPaneLayout` / `fourPaneLayout` の 2 ブランチで実装
  - `.singleBottom` / `.split`: 既存ロジックを `isCollapsed` で渡す（isVertical=false で同型のため in-place 更新）
  - `.splitHorizontal`: `isVertical: true`, ratio=0.5 で `SplitPane`（topPane=左、bottomPane=右）
  - `.splitFour`: 外側 `isVertical:true` + 内側 2 つの `isVertical:false` をネスト（ratio=0.5 ずつ）

### Phase 3: タブバー UI（TabsView） [AI🤖]

- [x] `paneByID` に `topRightPane` / `bottomRightPane` を追加
- [x] `paneIsVisible` を前提セクションの switch 実装に更新
- [x] 既存トグルボタン 1 個を `layoutButton` ヘルパ × 4 ボタンに置き換え
  - アクティブなレイアウトは `Color.accentColor` の前景色でハイライト（アイコン色変更）

### Phase 4: ショートカット更新 [AI🤖]

- [x] `ShortcutsStore.swift`:
  - [x] `togglePaneLayout` action を削除
  - [x] `setPaneLayoutSingle` / `setPaneLayoutSplit` / `setPaneLayoutHorizontal` / `setPaneLayoutFour` の 4 action を追加（デフォルト: Cmd+Opt+1/2/3/4）
  - [x] `FixedShortcuts.all` — リバインド可能な action なので追加不要（固定ではない）
- [x] `MRUKeyMonitor.swift`:
  - [x] `togglePaneLayout` の呼び出しを 4 つの `setPaneLayout` 呼び出しに差し替え
  - [x] `focusPane` / `moveTab` の guard を `ws.paneLayout != .singleBottom && (ws.activePane === ws.topPane || ws.activePane === ws.bottomPane)` に変更

### 動作確認 [AI🤖 + 人間👨‍💻]

**AI が実施**
- [x] `mise run build` が通ること
- [x] `polepole-launch.sh` + `polepole-screenshot.sh` で 4 ボタンが表示されていること（split がハイライト確認済み）
- [x] 各レイアウトのスクリーンショット確認（split/singleBottom/splitHorizontal/splitFour）  
  - `split`: 上下2段分割 ✅  
  - `singleBottom`: 1ペイン ✅  
  - `splitHorizontal`: 左右2列分割 ✅（`loadView()` で `custom.isVertical = isVertical` 未設定だったバグを修正）  
  - `splitFour`: 2×2グリッド ✅
- [x] `projects.json` に `splitHorizontal` raw value が保存されること（`projects.json` で確認済み）
- [x] 旧 JSON（`paneLayout` キーなし）で起動し、`.split` フォールバックで正常起動すること確認

**人間が実施（目視必須）**
- [ ] 各ボタンでレイアウトが正しく切り替わり、アクティブボタンがハイライトされる
- [ ] `.splitFour` → `.singleBottom` 切替時に右列ターミナルが消える（残影なし）
- [ ] Cmd+Opt+1〜4 で各レイアウトに切り替わる
- [ ] 4 ペイン時にタブ D&D が全ペイン間で動作する
- [ ] `.splitFour` → `.singleBottom` で文字入力が `bottomPane` に届く（hidden pane に入らない）

### 完了後 [AI🤖]

- [x] `VERIFY.md` に複数ペインレイアウトの確認手順を追記（セクション 7「複数ペイン」を4レイアウト対応に更新）

---

## ログ

### 試したこと・わかったこと

- `splitFour` で `SplitPane`（NSViewControllerRepresentable）をネストするとクラッシュ → `FourPaneSplit` + `FourPaneViewController` で AppKit のみで構成して解消
- `splitHorizontal` が上下分割に見えた原因: `RatioSplitViewController.loadView()` で `custom.isVertical = isVertical` を設定していなかった。`super.loadView()` 前に設定する必要がある
- `polepole-keystroke.sh --cmd-opt 3` の引数形式は未サポート。修飾キー付きキーストロークは `osascript` で直接 `key code N using {command down, option down}` を送る

### 方針変更
