# コード整理パス（SIMPLIFICATION 実装順 8 ステップ + 小粒パスコピー）

## 概要・やりたいこと

かつて `docs/SIMPLIFICATION_OPPORTUNITIES.md`（クローズ後に削除済み・内容は git history 参照）の棚卸しで挙がった「やった方がいい」項目を、同ドキュメントの「## 実装順のおすすめ」の順番で一気に片付けた。機能はほぼ変えず、処理量・記述量・壊れ方を減らすのが目的。ついでに `docs/BACKLOG.md` の小粒（Cmd+P / Cmd+Shift+F の Cmd+C パスコピー）も最後に入れた。

このプランはクローズ済み（[ログ](#ログ)参照）。各ステップの「（参照: SIMPLIFICATION P0-2）」等の P 番号は、その削除済みドキュメント内の項目番号（行番号・根拠・確認手順を含む詳細はそちらにあった）。

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
- [x] 特になし（Phase 7 の Release 検証だけ後段で人間作業）
- Phase 7 検証（`automation.apple-events` 削除後のターミナル描画/IME/クリップボード確認）は **単体でリリースを切らず、次に何かの理由でリリースするタイミングに相乗り**させて消化する。低リスク変更なのでブロッカー扱いしない。NG なら `Resources/IDE.entitlements` に entitlement を戻してログに残す。

### Phase 1: `ProcessRunner` + `BinaryLocator` を作る [AI🤖]
（参照: SIMPLIFICATION P0-2）
- [x] `Sources/ide/ProcessRunner.swift` 新規作成
  - [x] `BinaryLocator`: `.git` / `.grep` / `.cursor`（候補パスを 1 箇所に集約。`locateGit()` の二重実装＋優先順位不一致を解消）
  - [x] `run(executable:arguments:cwd:stdin:timeout:maxStdoutBytes:)` 相当の API
  - [x] stdout / stderr の**両方を drain**（pipe バッファ詰まり回避）
  - [x] stdin への供給は別 queue で stdout drain と並行（`GitIgnoreChecker` の stdin→stdout デッドロック回避）
  - [x] timeout で terminate → 数秒後も生きていれば SIGKILL
  - [x] 戻り値に `exitCode` / `timedOut` / `stdout` / `stderr` / `stdoutTruncated`
- [x] `mise run build` が通ることを確認
- [x] コミット

### Phase 2: `FullTextSearcher` / `GitStatusModel` / `GitIgnoreChecker` を `ProcessRunner` に載せ替え [AI🤖]
（参照: SIMPLIFICATION P0-2, P1-3 短期）
- [x] `GitStatusModel.runGitStatus` を `ProcessRunner` 経由に
- [x] `GitIgnoreChecker.check` を `ProcessRunner` 経由に（stdin 供給を drain と並行に）
- [x] `FullTextSearcher.run` を `ProcessRunner` 経由に
  - [x] `maxStdoutBytes`（4MB）で打ち切り（grep が上限超えても出し続ける問題を解消）
- [x] 各所の `locateGit()` / `locateGrep()` を `BinaryLocator` に置換、重複削除（`openInCursor` も）
- [x] `mise run build` 通過。launch して crash なし（screenshot は当環境の TCC 制約で不可、目視はユーザー検証へ）
- [x] コミット

### Phase 3: `setActive` から永続化を外す + `lastOpenedAt` 整理 [AI🤖]
（参照: SIMPLIFICATION P0-1）
- [x] `setActive(_:)` は `activeProject` / workspace / unread / MRU 更新だけにし、`persist()` を呼ばない
- [x] `lastOpenedAt = .now` の更新を `setActive` から外す（`unpin` 内の更新は `togglePin` 経由で persist されるので据え置き）
- [x] `addTemporary` に `persist()` を明示追加
- [x] `lastOpenedAt` は decode/encode とも据え置き（encode から外すのは schema v2 で）
- [x] `apply(&activeProject!)` の force-unwrap を `syncActive(to:)` に置換
- [x] 確認: AUTO_ACTIVATE 起動後に `projects.json` の mtime が変わらないこと（実測 pass）
- [x] コミット

### Phase 4: `FilePathKey` 導入 [AI🤖]
（参照: SIMPLIFICATION P0-4）
- [x] `struct FilePathKey: Hashable, Codable, Sendable { let path: String; init(_ url: URL) }` を追加
- [x] `FileTreeModel`: `expanded` / `scannedDirs` を `Set<FilePathKey>` に、`selectedURL` 比較は `isSelected(_:)`、`findNode` の `node.url` 比較も `FilePathKey` に
- [x] `FilePreviewModel`: `history` の重複判定と `currentURL` 比較を `FilePathKey` ベースに
- [x] `GitIgnoreChecker.check` の戻り値を `Set<FilePathKey>` に、呼び出し側（`FileIndex.scan` / `FileTreeModel.applyIgnored`）も合わせる
- [x] `FileIndex.recents` を `[FilePathKey: Date]` に
- [x] 確認: `mise run build` 通過 + launch crash なし（symlink 混在の目視はユーザー検証へ）
- [x] コミット

### Phase 5: プレビューのサイズ判定を先頭へ [AI🤖]
（参照: SIMPLIFICATION P0-3）
- [x] `FilePreviewClassifier.classify`: `fileExists` 直後に `attributesOfItem` で size を取得し、画像 / PDF / テキストすべてに `warnSize`（5MB）/ `externalSize`（50MB）を適用（拡張子判定より前）。`allowLarge` 引数で「読み込む」確認後の再分類に対応
- [x] `FilePreviewView`: `forceLoadLarge` は `.onChange` で再分類（`allowLarge: true`）を発火するトリガに変更し、View body の `Data(contentsOf:)` 直呼びを廃止。`.tooLarge` ケースは常に確認 UI（再分類で実際の種別に化ける）
- [x] （任意）画像 downsample は見送り
- [x] 確認: `mise run build` 通過（5/50MB 境界の目視はユーザー検証へ）
- [x] コミット

### Phase 6: `git ls-files` ベースの Cmd+P scan（Git repo のみ）[AI🤖]
（参照: SIMPLIFICATION P1-1。挙動変化あり → 上の「想定挙動変化」参照）
- [x] Git repo では `git ls-files -co --exclude-standard -z`（`ProcessRunner` 経由）でファイル一覧を取得し、親ディレクトリを合成して `Entry` を作る（`scanViaGit`）
- [x] `includeIgnored=true` のときは現行 BFS（`scanViaBFS`）を使う
- [x] 非 Git repo は `scanViaBFS` を使う（exit code != 0 でフォールバック）
- [x] `.git` は `git ls-files` がそもそも列挙しないので明示除外不要
- [ ] ~~（任意）検索/ツリーの除外ポリシー一元化（P1-2）~~ → 見送り（ログ参照）
- [x] 確認: `git ls-files -co --exclude-standard -z` の出力を実測（`.git/` なし、`.gitignore` 等の隠しファイルあり、ignored ファイルなし）。`mise run build` 通過
- [x] コミット

### Phase 7: セキュリティ quick wins [AI🤖]
（参照: SIMPLIFICATION P1-6, P1-7, P1-8, P1-9）
- [x] `Resources/IDE.entitlements` から `com.apple.security.automation.apple-events` を削除（残り 3 つの hardened runtime 例外は libghostty 由来の可能性が高いので**残す**）
- [x] `PreviewWebView`: `PreviewPayload` に `allowedRoot`（= project root）を持たせ、file URL は root 配下のみ同一プレビューで開く。root 外はパスをコピー + toast。コードプレビューにも適用
- [x] `ShellEscaper` を `ClipboardSupport` から独立。`openInTerminal` は `cd \(ShellEscaper.escape(dir.path))\n` に、unused な `workspace` / `pane` / `tab` 取得 + `FileTreeView` の `projects` プロパティを削除
- [x] `ClipboardSupport`: クリップボード画像を `~/Library/Caches/{ide,ide-dev}/clipboard/` に保存。`AppPaths.cacheDirectory` を追加（Release/Debug 分離）。起動時（`IdeApp.init`）に `cleanupOldClipboardImages()` で 1 日以上前のものを削除。`/tmp/clipboard-...` 表記も修正
- [x] `mise run build` 通過 + Debug 起動 crash なし（Markdown リンク / ターミナルで開く / 画像 paste の目視はユーザー検証へ）
- [x] コミット

### Phase 7 の検証 [人間👨‍💻]
- [ ] `scripts/build.sh` で Release ビルド + 署名 + notarize
- [ ] 実機で起動し、ターミナル描画 / IME / クリップボードが正常に動くこと（= `automation.apple-events` を外しても libghostty が困らないこと）
- [ ] NG だったら entitlement を戻す（ログに残す）

### Phase 8: `PocLog` → `Logger` 一本化 [AI🤖]
（参照: SIMPLIFICATION P1-5, BACKLOG「優先度: 高め」）
- [x] `PocLog.write` の call site を全部 `Logger.shared.debug` に置換、`Logging.swift` を削除
- [x] `/tmp/ide-poc.log` は Debug ビルド限定で `Logger` のミラーとして残す（`Logger.shared.resetDebugMirror()` で起動時クリア）
- [x] stderr 二重出力が消えていること（`'app_new ok'` が stderr に 1 回）、`~/Library/Logs/ide-dev/` と `/tmp/ide-poc.log` 両方に出ることを確認
- [x] CLAUDE.md / docs/DEV.md / docs/ARCHITECTURE.md の「PocLog 撤去予定」記述を実態に合わせて更新
- [x] コミット

### Phase 9: 小粒 — Cmd+P / Cmd+Shift+F の Cmd+C パスコピー [AI🤖]
（参照: BACKLOG「優先度: 低め」step10 / step11 由来。今回まとめてやる）
- [x] `QuickSearchView`/`MRUKeyMonitor`: 選択中エントリで `Cmd+C` → 相対パスをクリップボードへ + info toast（選択なしなら素通り）
- [x] `FullSearchView`/`MRUKeyMonitor`: 同様に選択中ヒットの相対パスを `Cmd+C` でコピー
- [x] 確認: `mise run build` 通過 + launch crash なし（overlay 上での Cmd+C 目視はユーザー検証へ）
- [x] コミット

### 仕上げ [AI🤖]
- [x] `docs/SIMPLIFICATION_OPPORTUNITIES.md` に「消化状況」セクションを追加
- [x] `docs/BACKLOG.md`: 「優先度: 高め」の `PocLog`→`Logger` 行を削除、冒頭ポインタを更新（step10/step11 の Cmd+C 行・P1-8 行も消化済みに更新）
- [ ] `/retro` で振り返りを提案

### 動作確認 [人間👨‍💻]
- [ ] 普段使いで Cmd+P / Cmd+Shift+F / プレビュー / git バッジ / ターミナルで開く / 画像 paste が体感で劣化していないこと
- [ ] Release 検証（Phase 7 の検証と兼ねる）

## ログ
### クローズ（2026-05-12）
- Phase 1〜9 + 仕上げ（SIMPLIFICATION の消化状況追記・BACKLOG 整理）まで完了したのでこのプランはクローズ。詳細リファレンスだった `docs/SIMPLIFICATION_OPPORTUNITIES.md` はクローズ後に削除した（内容は git history 参照）。
- 残った人間作業（Phase 7 の Release 実機検証、普段使いでの体感確認）と未消化の長尾（P1-2 / P1-4 / P2-1〜P2-3 / P2-5）は `docs/BACKLOG.md` の「優先度: 低め」表へ移した。

### 試したこと・わかったこと
- 当環境（Claude Code の Bash）は画面収録 TCC 権限が無く `ide-screenshot.sh` が `could not create image from display` で落ちる。各 Phase の検証は「`mise run build` 通過 + `launch` して crash なし + ログ確認 + 可能なら test 用フラグ + 外部コマンド出力の実測」に倒し、UI 目視はユーザー検証に委ねた。
- Phase 3 検証: 固定フィクスチャ + `IDE_TEST_AUTO_ACTIVATE_INDEX` で起動し、起動前後で `~/Library/Application Support/ide-dev/projects.json` の mtime が不変であることを確認（setActive が persist しなくなった証跡）。
- Phase 6 検証: `git ls-files -co --exclude-standard -z` の出力を ide リポジトリで実測。`.git/` 配下なし、`.gitignore` `.mise.toml` 等の隠しファイルあり、`*.xcodeproj` `.refs/` 等の ignored は出ない、を確認。
- Phase 8 検証: stderr に `app_new ok` が 1 回だけ出る（旧実装は PocLog と Logger 双方が stderr に書いて 2 回出ていた）。`~/Library/Logs/ide-dev/` と Debug ミラー `/tmp/ide-poc.log` の両方に出力。

### 方針変更
- Phase 5: `.tooLarge` のときの「読み込む」を、従来の「View body で `Data(contentsOf:)` を直読みして code として表示」から「`forceLoadLarge` を立てて `classify(allowLarge: true)` で再分類 → 実際の種別（image/pdf/code）でレンダリング」に変更。これで巨大画像/PDF も確認 UI を経たうえで正しい種別で表示でき、読み込み経路も classify の Task に一本化される。
- Phase 6: P1-2（検索/ツリーの除外ポリシー一元化）は「無理しない」枠だったので今回は見送り（`scanViaBFS` 側の `alwaysSkipDirNames` / `cheapSkipDirNames` と `FullTextSearcher` の `--exclude-dir` がまだ別々）。SIMPLIFICATION の「未着手」に残した。
- Phase 7: P1-7 は `automation.apple-events` の削除のみ実施。残り 3 つの hardened runtime 例外（allow-jit / allow-unsigned-executable-memory / disable-library-validation）は libghostty 由来と推定されるため据え置き。`automation.apple-events` を外しても問題ないかの Release 実機検証は人間作業（Phase 7 の検証）。
- Phase 8: `/tmp/ide-poc.log` は VERIFY で `tail -f` 用に便利なので削除せず、`#if DEBUG` の Logger ミラーとして残した（`PocLog` 型自体は削除、`PocLog.reset()` → `Logger.shared.resetDebugMirror()`）。
- Phase 9: Cmd+C は overlay 表示中かつ「選択中エントリが存在する」ときだけ event を消費する。選択が無いときはパイプラインに流す（検索フィールドで選択したテキストの通常コピーを妨げないため）。
