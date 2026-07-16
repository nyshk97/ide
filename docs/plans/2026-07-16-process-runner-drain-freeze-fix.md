# ProcessRunner drain スレッドリーク根治 + ファイルツリー reload フリーズ解消

## 概要・やりたいこと

ファイルツリーの再読み込みでアプリ全体がフリーズ（虹色ぐるぐる）する問題を根治する。

問題は2層構造:

1. **劣化状態のスパイラル（根本原因）**: `ProcessRunner` の stdout/stderr drain が concurrent queue 上のブロッキング `availableData` ループで実装されており、EOF が来ない pipe が一度発生すると、タイムアウト時に read handle を close しても blocked read は解放されない（macOS では close は blocked read を起こさない）。タイムアウトごとに GCD ワーカースレッドが最大2本永久リークし、プール（〜64本）枯渇後は**全外部コマンドが `stdoutBytes=0` で2秒タイムアウト**する自己増殖状態に入る。アプリ再起動まで回復しない
2. **フリーズ（症状）**: `FileTreeModel.reload()` が `@MainActor` 上から `GitIgnoreChecker.check` →`ProcessRunner.run` を展開ディレクトリ数ぶん同期直列実行する。劣化状態では 2秒 × N でメインスレッドがブロックする

ログ実績: 劣化状態は少なくとも2エピソード発生済み（7/11 朝〜 約8,800件、7/15 17:59〜7/16 10:58 強制終了まで約22,000件の drain timeout WARN）。ユーザー体感の「Cmd+Shift+F が遅い」「git バッジが遅い」「Cmd+D が重い」も同一原因（すべて ProcessRunner 経由）。

修正後は **1.4.17 hotfix として即リリース**する。

## 前提・わかっていること

- drain timeout WARN の実体: `ProcessRunner.swift:191` の `group.wait(timeout: .now() + 2)`。`exit=0 stdoutBytes=0` = git は正常終了したのに drain ブロックが1バイトも読めていない（プール枯渇で drain ブロックがそもそも実行されていない）
- メインスレッドから `ProcessRunner.run` を呼ぶのは **`FileTreeModel` だけ**（`reload()` / `scanIfNeeded()` の `applyIgnored` 経由）。`FileIndex` rebuild・`GitStatusModel`（3秒ポーリング）は `Task.detached` で既にバックグラウンド
- `FileIndex.swift:366` も `GitIgnoreChecker.check` を呼ぶが background なので、`GitIgnoreChecker` 自体は同期 API のまま維持し、FileTreeModel 側で逃がす
- EOF 不達 pipe の初期トリガ最有力: `Pipe()` 生成〜`FD_CLOEXEC` 設定の隙間に別プロセスが並行 spawn されると write 端 fd が子に継承されて漏れる CLOEXEC レース。ProcessRunner 内の spawn 同士は直列化で潰せる。libghostty のシェル spawn 経路は制御外で残るが、イベント駆動化後は実害が「その1回が2秒遅い」だけに縮小する
- `FileNode` は non-Sendable な class。`polepoleTests` ターゲットは存在する（`project.yml` の test scheme 参照）
- 直近の b0f945b「fix: 外部コマンドの出力待ち停止を防ぐ」がこの周辺の修正で、今回はその取り残し（タイムアウト時のスレッドリーク）という位置づけ
- `polepoleTests/ProcessRunnerTests.swift` に EOF 不達（`(sleep 10) &` が stdout write 端を握り続ける）の基本ケースが既にある。劣化テストの fixture はこの方式を流用する（FD 継承ヘルパの新設は不要）
- stdin 書き込みのブロックは「子が read しない + stdin が pipe 容量 64KB 超」で起きるが、timeout kill → read 端 close → EPIPE で解放されるため**上限は timeout 秒で有界**。永久リークにはならないので stdin の完全イベント駆動化はせず、SIGPIPE 対策付きの安全な書き込み + テストで担保する。ただし「timeout kill が必ず発火する」保証のため、timeout 監視は GCD プール（ioQueue）に置かず caller スレッド自身で執行する（Phase 1 参照）

### 成功条件

- ファイルツリーのリロード・展開でメインスレッドがブロックしない（劣化状態でも）
- drain timeout が発生しても**スレッド/ハンドラをリークせず、後続の外部コマンド実行が健全**（= スパイラルに入らない）
- 単発の drain timeout 自体はゼロにはならない（libghostty 経由の CLOEXEC レースは制御外）。頻度低下は期待するが成功条件には含めない

### /dig での決定事項

| 論点 | 決定 |
|---|---|
| スコープ | 根治+即効薬を1リリースで |
| drain 方式 | `readabilityHandler` によるイベント駆動化（`run()` の同期 API は維持、待機スレッドゼロ） |
| reload async 化 | ディレクトリスキャン（FileManager）は main で即実行・即表示。ignore 判定だけ `Task.detached` で後追い反映。`scanIfNeeded` も同様。連打・再入対策に世代トークン |
| hideIgnored ON 時のちらつき | 許容（後追い反映で一瞬 ignored ファイルが見えてから消える。デフォルト OFF の設定なので対策しない） |
| CLOEXEC レース緩和 | ProcessRunner 内で pipe 生成〜`process.run()` を lock で直列化 |
| ログ | drain timeout WARN にレート制限（60秒集約 + 抑制した件数付きで出力） |
| テスト | polepoleTests に劣化状態の再現テストを追加 |
| リリース | 1.4.17 hotfix |

## 実装計画

### Phase 1: ProcessRunner のイベント駆動化 [AI🤖]

- [x] stdout/stderr drain を `availableData` ブロッキングループから `FileHandle.readabilityHandler` に置き換える（チャンク追記・`maxStdoutBytes` 超過時 terminate・EOF（空 Data）でハンドラ解除+完了通知、は現行と同等の挙動を維持）
- [x] **stream ごとに「完了を一度だけ」保証する状態機械（lock 付き）を置く**: EOF / drain timeout / `maxStdoutBytes` terminate / 起動失敗の4経路が競合しても、ハンドラ解除・handle close・`group.leave()` がちょうど1回だけ走る。完了後（結果返却後）に sink へ追記しない
- [x] 完了待ちは `DispatchGroup` を維持しつつ、タイムアウト時は状態機械経由で `readabilityHandler = nil` → close し、**スレッドを一切残さず**破棄する
- [x] drain の EOF 猶予（現行 `group.wait(.now() + 2)` の2秒）を内部で注入可能にする（テストから短縮できるように。デフォルトは2秒のまま）
- [x] stdin 供給を EPIPE で例外を出さない `write(2)` ベースの安全な書き込みにする（broken pipe = 子が先に exit / read 端 close で正常に打ち切り。ブロックしても process timeout の kill で read 端が閉じて解放される = 有界）。**stdin の write fd には `F_SETNOSIGPIPE` を設定する**（Darwin では read 端が閉じた pipe への素の `write(2)` は EPIPE を返す前に SIGPIPE でプロセスごと落ち得るため、EPIPE として処理させる）
- [x] **timeout 監視・SIGKILL を ioQueue から分離する**: stdin write のブロックが GCD ワーカープールを塞ぐと同一プール上の timeout work も発火せず「timeout kill で解放される」前提が崩れる。timeout は caller スレッド自身で執行する — `waitUntilExit()` を `terminationHandler` + semaphore に置き換え、`semaphore.wait(timeout:)` の期限切れで caller スレッドが terminate → SIGKILL を直接実行する（`run()` は同期 API なので caller スレッドは必ず存在し、プール枯渇の影響を受けない）
- [x] pipe 生成（`Pipe()` + `markCloseOnExec`）〜 `process.run()` を static lock で直列化（CLOEXEC レース**緩和**。Darwin には `pipe2(2)` が無く原子的な `O_CLOEXEC` 指定は不可能なため、根治ではないことを成功条件に反映済み）
- [x] drain timeout WARN にレート制限を実装: 同一 executable の連発は60秒窓で集約し「(直近60秒でN件抑制)」形式で出力
- [x] `mise run build` が通ることを確認

### Phase 2: 劣化状態の再現テスト [AI🤖]

fixture は既存 `ProcessRunnerTests.swift` の `(sleep N) &` 方式を流用する（FD 継承ヘルパは新設しない）。連続実行テストは Phase 1 で注入可能にした EOF 猶予を短く（例: 0.2秒）して回し、fixture の sleep も短く（例: 2〜3秒）してテスト終了時に自己回収させる。

- [x] テスト1: EOF 不達 pipe でも `run()` が猶予経過後に結果を返す（ハングしない）— 既存テストを注入 API 対応に更新
- [x] テスト2: EOF 不達タイムアウトを短い猶予で連続 20 回発生させても、直後の正常な `run()` が健全（stdout が正しく読める・所要時間が正常）= スレッド/ハンドラ非リークの回帰検証
- [x] テスト3: stdin を読まない子（`sh -c 'sleep 5'`、**`timeout: 0.2` を明示**して自然終了ではなく timeout kill 経路を通す）に 64KB 超の stdin を渡してもクラッシュせず解放される / 子が即 exit した後の stdin 書き込み（EPIPE/SIGPIPE）でも落ちない
- [x] テスト4: 正常系の回帰（stdout 大量出力・stdin 供給・`maxStdoutBytes` 打ち切り・timeout kill が現行どおり動く）
- [x] xcodebuild test で全テストが通る

### Phase 3: FileTreeModel.reload の ignore 判定後追い化 [AI🤖]

- [x] `reload()` / `scanIfNeeded()` から `applyIgnored` の同期呼び出しを外し、ディレクトリスキャン結果は即時ツリー反映する
- [x] ignore 判定の後追い反映: **`Task.detached` には Sendable な値だけ渡す**（対象パスの `[URL]`（値型）+ 世代番号。`FileNode` は non-Sendable なので capture 禁止）。`GitIgnoreChecker.check` の結果 `Set<FilePathKey>` を受けて MainActor に復帰し、**現行ツリーからパスで node を検索し直して** `isIgnored` を更新する
- [x] 世代トークン（reload 世代カウンタ）を導入し、反映時に世代が変わっていたら結果を丸ごと捨てる（連打・展開操作との競合対策）
- [x] テスト seam を用意する: FileTreeModel の ignore 判定呼び出しを closure（例: `var ignoreChecker: @Sendable (URL, [URL]) -> Set<FilePathKey>`、デフォルトは `GitIgnoreChecker.check`）として注入可能にし、テストから遅延・結果を決定的に制御できるようにする
- [x] FileTreeModel のテストを追加: (a) reload 後に届いた古い世代の ignore 結果が新しいツリーに反映されないこと (b) 展開直後の ignore 結果が該当ディレクトリ配下の正しい node にだけ反映されること（`@MainActor` の XCTest + 一時ディレクトリ fixture + 上記 seam）
- [x] `mise run build` が通り、追加テストが通ることを確認

### Phase 4: 動作確認 [AI🤖]

- [x] `./scripts/polepole-launch.sh` で起動し、ファイルツリー表示・ディレクトリ展開・リロードボタンで薄表示（ignored）が正しく付くことをスクリーンショットで確認
- [x] `/tmp/polepole-poc.log` で drain timeout WARN が出ていないこと、reload 後に git check-ignore が background で完走していることを確認
- [x] VERIFY.md のファイルツリー / git バッジ / Cmd+Shift+F / Cmd+D 関連セクションのうち今回の変更に関係する手順を実行
- [x] VERIFY.md に再利用可能な確認手順（劣化状態の再現テストの回し方等）が未記載なら追記

### 動作確認（目視） [人間👨‍💻]

- [x] 普段のプロジェクトでツリーのリロード・展開の体感確認（引っかかりがないか）
- [x] hideIgnored ON でのちらつきが許容範囲か一応見る

### Phase 5: リリース 1.4.17 [AI🤖 + 人間👨‍💻]

- [x] [AI🤖] `project.yml` の `MARKETING_VERSION` を 1.4.17 に bump してコミット
- [x] [AI🤖] `docs/CHANGELOG.md` の `[Unreleased]` にリリースノートを記載（ヘッダー自体は書き換えない）してコミット
- [x] [人間👨‍💻] 通常 Terminal で `echo "" | bash scripts/release.sh 1.4.17` を実行（notarytool 資格情報が Claude Code の Bash からは届かないため）
- [x] [AI🤖] Homebrew cask (`nyshk97/homebrew-tap/Casks/polepole.rb`) の version / sha256 更新 → commit → `pull --rebase` → push
- [x] [AI🤖] 公式サイト changelog 再生成・デプロイ（`wrangler deploy` の predeploy で自動）

## ログ

### 試したこと・わかったこと
- 2026-07-16: Phase 1〜4 完了。ProcessRunnerTests 10件 + FileTreeModelTests 3件 全パス。
  実機（Dev 版）でツリー表示・ignore 薄表示の後追い反映を確認、drain timeout 0件。
- xcode-select が CLT を向いている環境では `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付けて xcodebuild を叩く
- テストファイル新規追加後は `mise run regen`（xcodegen）を挟まないと .xcodeproj に載らず「Executed 0 tests」になる
- Dev 版はトライアル切れモーダルが出る場合、`POLEPOLE_TEST_LICENSE_FAKE_NOW=<unix秒>` で時計を偽装して回避できる（installDate は Application Support の trial.json）

### 方針変更
- 2026-07-16 リリース時の想定外: `xcode-select` が CLT を向いていて release.sh の archive が失敗。
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付けて再実行で解決。
  失敗した初回実行が CHANGELOG のリネーム commit まで進んでいたため、再実行前に
  `git reset --soft HEAD~1` + restore で巻き戻してヘッダー重複（Sparkle description 空）を回避した
- 2026-07-16 レビュー指摘対応: stdin 供給を同期 write(2) から **DispatchSourceWrite（writability 駆動 + non-blocking）** に変更。
  「子は exit 済みだが子孫が stdin read 端を継承して保持」のケースでは timeout kill が
  発火せず同期 write が永久ブロックしてワーカーがリークするため（plan 当初の
  「timeout 秒で有界」の前提が崩れる経路）。再現 fixture は `exec 3<&0; sleep 3 & exit 0`
  （素の `sleep &` は POSIX 仕様で background job の stdin が /dev/null になり再現しない）。
  20連発 + 後続健全性のテストを追加済み（72aef5a）
