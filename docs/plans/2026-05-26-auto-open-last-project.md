# 起動時に直近のプロジェクトを自動で開く

## 概要・やりたいこと

PolePole は起動直後、どのプロジェクトも選択されていない空状態になる。これを変更し、「最後に開いていたプロジェクトを起動時に自動で開く」挙動にする。IDE として最後の作業状態に自然に戻れるようにするのが目的。

## 前提・わかっていること

### 現状

- `Sources/polepole/PolePoleApp.swift:5-38` がエントリポイント。`init()` で `Ghostty` などを初期化し、`ContentView` → `RootLayoutView` → `ProjectsModel.shared` の順
- `Sources/polepole/ProjectsModel.swift:9` に「再起動時に active を復元しない」旨のコメントがあり、現状は意図的に未選択状態で起動している
- `Sources/polepole/Project.swift:1-64` の `Project` モデルには既に `lastOpenedAt: Date` フィールドがある（Codable / ISO 8601）
- `ProjectsStore` (`Sources/polepole/ProjectsStore.swift`) が `~/Library/Application Support/{polepole, polepole-dev}/projects.json` を読み書き
- `ProjectsModel.setActive(_:)` (`ProjectsModel.swift:538-555`) がプロジェクトを開くパス。`activeProject = project` + `workspace(for:)` でシェル起動 + MRU スタックに記録
- テスト用に `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` 環境変数で index 指定の自動選択は既にある（`ProjectsModel.swift:155-163`）

### `lastOpenedAt` の更新タイミング（重要）

現状 `lastOpenedAt` は **unpin 時にしか更新されていない**（`ProjectsModel.swift:496` 付近）。pin したまま使い続けているプロジェクトは古い値のままなので、「直近」判定が狂う。`setActive()` のたびに `Date()` で更新する形に直す必要がある。

### サイドバーのソート順への影響: なし

`ProjectsModel.swift:145-149` のコメントに明記されている通り、`pinned` / `temporary` は「保存時の順序をそのまま復元」する仕様。`temporary` はかつて `lastOpenedAt` 降順で並べていたが、ドラッグ並び替え導入時に保存順維持に変更済み。サイドバー表示順 `allOrdered` (`L235`) は `pinned + temporary` の配列順そのもので `lastOpenedAt` でソートしていない。

つまり `setActive()` 内で `lastOpenedAt` を更新しても、`pinned` / `temporary` の配列順は変わらず、サイドバー表示順も変わらない。`lastOpenedAt` は `mruCandidates()` (Command Palette などの別 UI) と本タスクで追加する「起動時の自動選択」にだけ影響する。

### 決定事項（/dig-lite で確認済み）

- **逃げ道は用意しない**: Settings トグルや Option キーでのスキップなどは入れない。常に自動で開く
- **パスが消えていた場合**: `lastOpenedAt` 降順で次のプロジェクトを順に試し、有効なものが見つかったらそれを開く。全部無効なら何もしない（未選択のまま）
- **`lastOpenedAt` は `setActive()` で更新する**: pin 中でも最後にアクティブにした順序が正確に反映される

## 実装計画

### Phase 1: lastOpenedAt の更新タイミング修正 [AI🤖]

- [ ] `ProjectsModel.setActive(_:)` 内で、選択対象の Project の `lastOpenedAt` を `Date()` に更新する
- [ ] 更新後に `ProjectsStore` 経由で永続化される経路を確認（既存の save パスに乗るか、明示的に呼ぶ必要があるか）
- [ ] unpin 時の `lastOpenedAt` 更新（既存ロジック）と二重に走らないか確認。`setActive()` での更新で十分なら冗長な書き込みを残してもよいが、意図を整理する

### Phase 2: 起動時の自動選択 [AI🤖]

- [ ] `ProjectsModel.init()` の `load()` 直後（`ProjectsModel.swift:91-110` 付近）に自動選択ロジックを追加
- [ ] `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` が設定されている場合は従来通り index 指定を優先（既存のテストパスを壊さない）
- [ ] それ以外では `projects` を `lastOpenedAt` 降順でソートし、`FileManager.default.fileExists(atPath:)` で path の有無をチェック。最初に有効だったプロジェクトを `setActive()` で開く
- [ ] すべて無効だった場合は未選択のまま起動（現状維持）
- [ ] pin / temporary の区別なく `lastOpenedAt` だけで選ぶ（最後に触った順が正なので）

### 動作確認 [AI🤖 + 人間👨‍💻]

- [ ] [AI🤖] `mise run build` が通る
- [ ] [AI🤖] `./scripts/polepole-launch.sh` でアプリ起動 → `./scripts/polepole-screenshot.sh` で「直前に開いていたプロジェクトが選択された状態」になることを確認
- [ ] [AI🤖] プロジェクトを別のものに切り替え → kill → 再起動で「切り替え後のプロジェクト」が開くこと（`lastOpenedAt` が `setActive()` で正しく更新されているか）
- [ ] [AI🤖] テスト用に projects.json を編集して `lastOpenedAt` が最新のプロジェクトの path を存在しないものに差し替え、次点のプロジェクトが開くことを確認（fallback ロジック）
- [ ] [AI🤖] projects.json を空にする / 全プロジェクトのパスを無効にする → 未選択状態で起動することを確認
- [ ] [AI🤖] `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0` での起動が引き続き動作することを確認（VERIFY.md の既存検証）
- [ ] [人間👨‍💻] 通常運用での体感確認

### Phase 3: CHANGELOG 追記 [AI🤖]

- [ ] `docs/CHANGELOG.md` の `[Unreleased]` セクションに `📝 Changed` で 1 行追加（ja/en ペア）
  - 例: `- ja: 起動時に最後に開いていたプロジェクトを自動で開くようになりました`
  - 例: `- en: PolePole now auto-opens the most recently used project on launch`

## ログ

### 試したこと・わかったこと

- Phase 1: `setActive(_:)` 内で `didSwitch` のときだけ `pinned` / `temporary` 配列の該当エントリの `lastOpenedAt` を `Date()` に更新 + `persist()`。`Project` は value type なので `func` 引数の `project` ではなく配列内のエントリを書き換える必要があった。
- Phase 2: `init()` の `applyTestAutoActivate()` の直後に `autoActivateLastOpenedProject()` を挿入。`activeProject == nil` ガードで `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` を優先する設計。
- 動作確認 1 (通常起動): `diff-viewer` の `lastOpenedAt` だけ未来時刻にして起動 → `diff-viewer` が自動選択されサイドバーでハイライト・ファイルツリー展開・シェル起動を確認。
- 動作確認 2 (fallback): 最新の `diff-viewer` の path を存在しないパスに差し替え → 次点の `alexa-skills` が自動選択されることを確認。`diff-viewer` はサイドバーで⚠️付き未選択。

### 方針変更
（特になし）
