# コード整理パス（SIMPLIFICATION 実装順 8 ステップ + 小粒パスコピー）

## 概要・やりたいこと

`docs/SIMPLIFICATION_OPPORTUNITIES.md` の棚卸しで挙がった「やった方がいい」項目を、同ドキュメントの「## 実装順のおすすめ」の順番で一気に片付ける。機能はほぼ変えず、処理量・記述量・壊れ方を減らすのが目的。ついでに `docs/BACKLOG.md` の小粒（Cmd+P / Cmd+Shift+F の Cmd+C パスコピー）も最後に入れる。

このプランが「進行中の整理」の正。詳細・行番号・確認手順は各ステップから `SIMPLIFICATION_OPPORTUNITIES.md` の P 番号を参照する。

各 Phase 完了時にコミットする（CLAUDE.md「実装中」の規約通り）。想定外の失敗・方針変更はログセクションに 1 件 10 行以内で追記する。

## 前提・わかっていること

- 対象は Phase 2 完了済みのコードベース。基本機能には満足しており、これは「機能追加」ではなく「整理」のパス。
- `SIMPLIFICATION_OPPORTUNITIES.md` の記述はコードと照合済み（致命的な誤りなし、`/tmp` 表記など軽微な不正確さは修正済み）。
- スコープに**含めない**（同ドキュメントの「やらなくてよさそうなこと」+ BACKLOG の「シグナル待ち / 当面やらない」）:
  - `ProjectsModel` の大分割（P2-1）、WebView singleton の作り直し（P2-4）、FSEvents 再挑戦、ripgrep バンドリング
  - missing project を active にしない（P1-4）、検索/ツリーの除外ポリシー一元化（P1-2）、foreground polling 間引き（P2-2）、node 探索の辞書化（P2-3）— 余力があれば触るが必須ではない
- Phase 7 の entitlement 変更は **Release configuration のみ**に影響。Debug は entitlements を使わない。検証には Release ビルド + notarize + 実機起動が要るので人間作業。
- 想定挙動変化:
  - Phase 6（`git ls-files` 化）で **gitignore されたファイル単位の対象**（例: gitignore された `.env`）が Cmd+P に出なくなる。要件 6.1 にはむしろ忠実だが体感は変わる。`includeIgnored=true` で従来通り全部出るようにする（fallback の現行 BFS でカバー）。
  - Phase 7（Markdown root 制限）でプロジェクト外のローカルファイルへの Markdown リンクは同一プレビューで開かず、コピー + toast になる。

## 実装計画

### 事前準備 [人間👨‍💻]
- [ ] 特になし（Phase 7 の Release 検証だけ後段で人間作業）

### Phase 1: `ProcessRunner` + `BinaryLocator` を作る [AI🤖]
（参照: SIMPLIFICATION P0-2）
- [ ] `Sources/ide/ProcessRunner.swift` 新規作成
  - [ ] `BinaryLocator`: `.git` / `.grep` / `.cursor`（候補パスを 1 箇所に集約。`locateGit()` の二重実装＋優先順位不一致を解消）
  - [ ] `run(executable:arguments:cwd:stdin:timeout:maxStdoutBytes:)` 相当の API
  - [ ] stdout / stderr の**両方を drain**（pipe バッファ詰まり回避）
  - [ ] stdin への供給は別 queue / `writabilityHandler` で stdout drain と並行（`GitIgnoreChecker` の stdin→stdout デッドロック回避）
  - [ ] timeout で terminate → 必要なら kill
  - [ ] 戻り値に `exitCode` / `timedOut` / `stdout` / `stderr`
- [ ] `project.yml` の regen が要れば回す、`mise run build` が通ることを確認
- [ ] コミット

### Phase 2: `FullTextSearcher` / `GitStatusModel` / `GitIgnoreChecker` を `ProcessRunner` に載せ替え [AI🤖]
（参照: SIMPLIFICATION P0-2, P1-3 短期）
- [ ] `GitStatusModel.runGitStatus` を `ProcessRunner` 経由に
- [ ] `GitIgnoreChecker.check` を `ProcessRunner` 経由に（stdin 供給を drain と並行に）
- [ ] `FullTextSearcher.run` を `ProcessRunner` 経由に
  - [ ] `maxStdoutBytes` または行単位処理で 1000 件に達したら terminate（grep が上限超えても出し続ける問題を解消）
- [ ] 各所の `locateGit()` / `locateGrep()` を `BinaryLocator` に置換、重複削除
- [ ] `mise run build` + `./scripts/ide-launch.sh` で git status バッジ / Cmd+Shift+F が動くこと、git が無い状態でも固まらないことを確認（VERIFY.md section 7, 10, 11）
- [ ] コミット

### Phase 3: `setActive` から永続化を外す + `lastOpenedAt` 整理 [AI🤖]
（参照: SIMPLIFICATION P0-1）
- [ ] `setActive(_:)` は `activeProject` / workspace / unread / MRU 更新だけにし、`persist()` を呼ばない
- [ ] `lastOpenedAt = .now` の更新を `setActive` から外す（`addTemporary` / `unpin` 等での更新は要否を見て判断）
- [ ] `addTemporary` など「永続状態が変わる操作」に `persist()` を明示的に追加（`setActive` 経由で persist していた箇所の補完）
- [ ] `lastOpenedAt` は decode は残し、当面値は据え置き（encode から外すのは schema v2 で。今回はやらない）
- [ ] `apply(&activeProject!)` の force-unwrap 周りもついでに整理（できる範囲で）
- [ ] 確認: Ctrl+M / サイドバークリックで `~/Library/Application Support/ide-dev/projects.json` の mtime が変わらないこと。pin/unpin/並び替え/rename/relocate/追加/閉じるでは変わること（VERIFY.md section 13, 14, 16, 17, 30 の関連分）
- [ ] コミット

### Phase 4: `FilePathKey` 導入 [AI🤖]
（参照: SIMPLIFICATION P0-4）
- [ ] `struct FilePathKey: Hashable, Codable { let path: String; init(_ url: URL) { path = url.standardizedFileURL.path } }` を追加
- [ ] `FileTreeModel`: `expanded` / `scannedDirs` / `selectedURL` の比較を `FilePathKey` ベースに
- [ ] `FilePreviewModel`: `history` の重複判定を `FilePathKey` ベースに（`currentURL == url` 等）
- [ ] `GitIgnoreChecker.check` の戻り値を `Set<FilePathKey>` に、呼び出し側（`FileIndex.scan` / `FileTreeModel.applyIgnored`）も合わせる
- [ ] `FileIndex.recents` を `[FilePathKey: Date]` に
- [ ] 確認: symlink / standardized path / file URL が混ざっても選択状態・履歴・ignore 表示が崩れないこと（VERIFY.md section 8, 9, 10）
- [ ] コミット

### Phase 5: プレビューのサイズ判定を先頭へ [AI🤖]
（参照: SIMPLIFICATION P0-3）
- [ ] `FilePreviewClassifier.classify`: `fileExists` 直後に `attributesOfItem` で size を取得し、画像 / PDF / テキストすべてに `warnSize`（5MB）/ `externalSize`（50MB）を適用（拡張子判定より前 or 直後）
- [ ] `FilePreviewView`: `forceLoadLarge` 時の `Data(contentsOf:)` を View body から直呼びせず、`classifyAndApply` と同じ async 経路で読むよう変更
- [ ] （任意）画像は `CGImageSourceCreateThumbnailAtIndex` で downsample も検討 — 重ければ別途
- [ ] 確認: 5MB 超画像/PDF が確認 UI、50MB 超が外部誘導になること（VERIFY.md section 23）
- [ ] コミット

### Phase 6: `git ls-files` ベースの Cmd+P scan（Git repo のみ）[AI🤖]
（参照: SIMPLIFICATION P1-1。挙動変化あり → 上の「想定挙動変化」参照）
- [ ] Git repo では `git ls-files -co --exclude-standard -z`（`ProcessRunner` 経由）でファイル一覧を取得し、親ディレクトリを合成して `Entry` を作る
- [ ] `includeIgnored=true` のときは現行 BFS（または別 fallback）を使う
- [ ] 非 Git repo は現行 `scan` を残す
- [ ] `.git` は何があっても出さない
- [ ] （任意）この機会に検索/ツリーの除外ポリシーを小さい enum にまとめられそうなら寄せる（P1-2）— 無理しない
- [ ] 確認: `.gitignore` 対象が通常出ない / `includeIgnored` で出る / 隠しファイルは含まれる（VERIFY.md section 25）
- [ ] コミット

### Phase 7: セキュリティ quick wins [AI🤖]
（参照: SIMPLIFICATION P1-6, P1-7, P1-8, P1-9）
- [ ] `Resources/IDE.entitlements` から `com.apple.security.automation.apple-events` を削除（残り 3 つの hardened runtime 例外は libghostty 由来の可能性が高いので**残す**）
- [ ] `PreviewWebView`: `PreviewPayload` に `allowedRoot`（= project root）を持たせ、file URL は root 配下のみ同一プレビューで開く。root 外はコピー + toast
- [ ] `FileTreeView.openInTerminal`: `shellEscape` を `ClipboardSupport` から独立した `ShellEscaper` に切り出し、`cd \(shellEscape(dir.path))\n` に。unused な `workspace` / `pane` / `tab` 取得を削除
- [ ] `ClipboardSupport`: クリップボード画像を `FileManager.default.temporaryDirectory` ではなく `~/Library/Caches/{ide,ide-dev}/clipboard/` に保存。`AppPaths` に `cacheDirectory` を追加（Release/Debug 分離）。起動時に 1 日以上前のものを削除。コード/コメントの `/tmp/clipboard-...` 表記も直す
- [ ] `mise run build` + Debug 起動で Markdown リンク / ターミナルで開く / 画像 paste が動くことを確認
- [ ] コミット（entitlement 変更は次の人間検証が通ってから本採用でもよい）

### Phase 7 の検証 [人間👨‍💻]
- [ ] `scripts/build.sh` で Release ビルド + 署名 + notarize
- [ ] 実機で起動し、ターミナル描画 / IME / クリップボードが正常に動くこと（= `automation.apple-events` を外しても libghostty が困らないこと）
- [ ] NG だったら entitlement を戻す（ログに残す）

### Phase 8: `PocLog` → `Logger` 一本化 [AI🤖]
（参照: SIMPLIFICATION P1-5, BACKLOG「優先度: 高め」）
- [ ] `PocLog.write` の call site を全部 `Logger.shared.debug` に置換
- [ ] `/tmp/ide-poc.log` が VERIFY で便利なら、Debug ビルド限定で `Logger` の mirror sink として残す（`PocLog.reset()` は Debug mirror だけ初期化）。不要なら `PocLog` ごと削除
- [ ] stderr 二重出力が消えていること、`~/Library/Logs/ide-dev/` にログが出ることを確認
- [ ] CLAUDE.md / docs/DEV.md / docs/ARCHITECTURE.md の「PocLog 撤去予定」記述を実態に合わせて更新
- [ ] コミット

### Phase 9: 小粒 — Cmd+P / Cmd+Shift+F の Cmd+C パスコピー [AI🤖]
（参照: BACKLOG「優先度: 低め」step10 / step11 由来。今回まとめてやる）
- [ ] `QuickSearchView`: 選択中エントリで `Cmd+C` → 相対パス（or 絶対パス）をクリップボードへ
- [ ] `FullSearchView`: 同様に選択中ヒットのパスを `Cmd+C` でコピー
- [ ] 確認: それぞれ overlay 表示中に `Cmd+C` でクリップボードに入ること
- [ ] コミット

### 仕上げ [AI🤖]
- [ ] `docs/SIMPLIFICATION_OPPORTUNITIES.md` の冒頭に「実行は `docs/plans/2026-05-12-code-cleanup-pass.md` で追跡」の一行、消化済み項目に印（or 削除）
- [ ] `docs/BACKLOG.md`: 「優先度: 高め」の `PocLog`→`Logger` 行を削除（消化済み）、冒頭ポインタを更新
- [ ] `/retro` で振り返りを提案

### 動作確認 [人間👨‍💻]
- [ ] 普段使いで Cmd+P / Cmd+Shift+F / プレビュー / git バッジ / ターミナルで開く / 画像 paste が体感で劣化していないこと
- [ ] Release 検証（Phase 7 の検証と兼ねる）

## ログ
### 試したこと・わかったこと
（実装中に随時追記）

### 方針変更
（実装中に随時追記）
