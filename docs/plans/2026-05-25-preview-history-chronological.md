# プレビュー履歴を時系列ログ化 + tree ハイライト同期

## 概要・やりたいこと

ファイルプレビューの back/forward を押したとき、ユーザーの期待と違うファイルが表示される問題を直す。

現状: `FilePreviewModel.open()` がブラウザ標準の「forward 履歴を truncate」ロジックを使っているため、`A → B → ← で A → C を開く` と B が消える。再度 ← を押すと B ではなく A が出る。

これを **時系列ログ (Option 1)** に変える: open() のたびに必ず append し、forward 履歴を truncate しない。back/forward は単純に時系列を辿る。

合わせて、独立ペイン化済みで tree と preview が常時並んで見えるようになったため、`fileTree.selectedURL`(tree のハイライト) が preview の navigation (← / →、markdown link) に追従しない問題も同じ PR で直す。

## 前提・わかっていること

### コードベース
- `FilePreviewModel.swift:17-32` の `open()` に truncate ブロック (L20-23) がある。これを削除するのが core change
- `FilePreviewModel.swift:121-131` の `goBack()` / `goForward()` は `currentURL` を更新するだけで `fileTree.selectedURL` を触っていない
- `FilePreviewView.swift:240` の markdown リンク経由 `preview.open(linked)` も `selectedURL` を更新していない
- tree click 経路 (`CenterPaneView.swift:73-74`) だけは両方更新している
- `FilePreviewModel` は `fileTree` を直接知らない (model 間結合を避ける設計)。同期は呼び出し側(View 層)で行う

### 設計判断 (確定済み)
- **history model**: 時系列ログ (Option 1)。常に append、forward truncate なし。連続同一ファイルの dedup (`last == key` で skip) と早期 return (`currentURL == key`) は維持
- **close() の挙動**: 現状通り history は保持。Cmd+J トグル (FileTreeView.swift:92 `preview.toggle()`) もそのまま動く
- **selectedURL 同期**: 今回の PR に含める (goBack/goForward/markdown link 経由でも追従)
- **history 上限**: 入れない。長セッションで肥大化したら後で考える
- **永続化**: しない (アプリ再起動でリセット、現状通り)
- **back/forward 矢印 UI**: 残す。独立ペイン後も「tree で探さずに直前の file に戻りたい」は有用

### ペイン独立化との関係
- 4 カラムレイアウト (dbb7132) で tree と preview は別ペインに分離済み
- `currentURL == nil` で preview pane が auto-collapse する設計
- tree ハイライトが常時可視になったため、selectedURL のズレが目立つようになっている

### 期待される挙動 (mov 再現フロー)

```
1. tree から growth-plan       → preview growth-plan      history=[growth-plan]            idx=0
2. close                                                  history 変わらず                  idx=0
3. tree から 32x32             → preview 32x32            history=[growth-plan, 32x32]     idx=1
4. ← back                      → preview growth-plan      history 変わらず (goBack は append しない) idx=0
5. close                                                  history 変わらず                  idx=0
6. tree から 160x160           → preview 160x160          history=[growth-plan, 32x32, 160x160] idx=2  ← 現状はここで 32x32 が truncate される
7. ← back                      → preview 32x32            idx=1   ← 現状は growth-plan (バグ)
8. ← back                      → preview growth-plan      idx=0
```

**履歴モデルの定義**: 「時系列ログ」= **`open()` 呼び出しだけを append する**。`goBack` / `goForward` で表示しただけのファイルは append しない (履歴配列を変えず idx を動かすだけ)。この前提なので、上記フローでも `growth-plan` は 1 度しか入らない。

## 実装計画

### Phase 1: history ロジックを時系列ログに変更 [AI🤖]
- [x] `Sources/polepole/FilePreviewModel.swift:17-32` の `open(_:)` を編集
  - `historyIndex < history.count - 1` の truncate ブロック (L20-23) を削除
  - 早期 return (`currentURL == key`) と `last == key` での skip は維持
  - コメントを「常に append (Option 1)」の意図に合わせて更新
- [x] `mise run build` でコンパイル確認

### Phase 2: tree ハイライトを preview に追従させる [AI🤖]
- [x] **案 B の variant で実装**: View 層ではなく `ProjectsModel.rewireActivePreviewSubscription(to:)` の sink を拡張して selectedURL も流す。理由: ここに集約すると初期値・rewire 時・全ての open() 経路を一発でカバーでき、View 側に `.onChange` + `.onAppear` の重複を入れずに済む
- [x] **nil を流さない**: sink の中で `if let url { tree.selectedURL = url }`。close (currentURL=nil) のときは selectedURL を保持
- [x] **初期同期**: rewire 直後に `preview.currentURL` を読んで `tree.selectedURL` に即反映 (sink は次の変化からしか発火しないので別途必要)
- [x] markdown リンク (FilePreviewView.swift:240) / Cmd+P (ProjectsModel.swift:367) / Cmd+Shift+F (ProjectsModel.swift:434) も `preview.open()` を通るため、sink 拡張だけで自動で乗る
- [x] `CenterPaneView.swift:73` の冗長な `fileTree.selectedURL = url` を削除 (sink が同じ役割を果たすため)
- [x] **スコープ限定**: 今回は「既にツリーに表示されているノードだけハイライト」。未展開配下は selectedURL は設定されるが行が無いのでハイライト見えない。reveal は別 plan
- [x] `mise run build` でコンパイル確認

### Phase 3: AI で確認できる範囲 [AI🤖]
- [x] `mise run build` がエラーなく通る
- [x] `POLEPOLE_TEST_AUTO_PREVIEW="README.md"` で起動 → /tmp/v-history-shallow.png で README.md がツリー上でハイライトされていることを確認 (初期同期 OK)
- [x] `POLEPOLE_TEST_AUTO_PREVIEW="docs/ARCHITECTURE.md"` で起動 → /tmp/v-history-deep.png で docs フォルダは閉じたままハイライトは見えない (スコープ通り)

### Phase 3.5: ユーザー目視確認 [人間👨‍💻]
**前提**: クリック・キーストロークの連打が要る検証は PolePole 内 Claude Code から自動化不可 (CLAUDE.md:54)。以下はユーザーに目視で頼む。

- [ ] mov 再現フロー (前提セクションの 8 step) を手動で実行し、Step 7 で 32x32 が、Step 8 で growth-plan が表示されること
- [ ] tree ハイライトが preview の現在ファイルに追従することを以下の経路で確認:
  - 通常の tree click 後
  - ← / → ボタンで navigation した後
  - markdown リンクで遷移した後
  - Cmd+P (recents) で開いた後 — 表示済みノードならハイライト、未展開ならハイライトなし (どちらも spec 通り)
  - Cmd+Shift+F (全文検索) の hit jump 後 — 同上
- [ ] preview を close したとき tree のハイライトが消えない (前回開いたファイルが薄く強調されたまま残る) こと
- [ ] Cmd+J トグルが現状通り動くこと (preview を閉じる → Cmd+J で最後のファイルが復元される) こと

### Phase 4: ドキュメント整備 [AI🤖]
- [x] `REQUIREMENTS.md` 6.4 を更新: 「ブラウザ風」を「時系列ログ方式」に。履歴のモデル節を新設し、open() だけが積まれる/forward truncate しない/← / → は index を動かすだけ、を明記。ペイン構成節を 4 カラムに合わせて改訂し、ツリーのハイライト追従についても追記
- [x] `VERIFY.md` 27 節を更新: 27.1 基本操作 / 27.2 forward 履歴の保持（mov 再現の 8 step） / 27.3 ツリーハイライト追従 + 未展開配下の注意書き
- [x] `docs/CHANGELOG.md` の `[Unreleased]` に Changed / Fixed の ja/en ペアを追加

### 最終確認 (人間) [人間👨‍💻]
- [ ] 長く使ってみて、back/forward の挙動が直感的になっているか体感確認

## ログ
### 試したこと・わかったこと
- 案 B を採用するときの最適置き場は `CenterPaneView` の `.onChange` ではなく、`ProjectsModel.rewireActivePreviewSubscription` の sink。理由: rewire 時の初期同期と sink 拡張の両方が同じ場所に書けて、`POLEPOLE_TEST_AUTO_PREVIEW` のような起動直後ケース・project 切替直後ケースを一発で拾える
- `CenterPaneView.swift:73` の `fileTree.selectedURL = url` は sink が代わりに発火するため削除した (Combine の @Published は同期発火するので race にはならない)
- AI からの動作確認は浅いパス (README.md) と深いパス (docs/ARCHITECTURE.md) の 2 パターンで screenshot を取得。深いパスはツリーに行が無いので「ハイライトが見えない」が期待動作

### 方針変更
- なし
