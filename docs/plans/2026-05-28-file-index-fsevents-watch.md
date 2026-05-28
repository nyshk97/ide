# FileIndex を FSEvents で自動更新する

## 概要・やりたいこと

Cmd+P のファイル検索 (`FileIndex`) が「プロジェクトを開いた時点のスナップショット」で固定されており、後から作成したファイル・リネーム・削除が反映されない。アプリ再起動するまで Cmd+P でヒットしない。

**目的**: project root を FSEvents で監視し、ファイルシステム変更を検知したら `FileIndex` を自動再構築する。ユーザー手動の reload は不要にする。

## 前提・わかっていること

### 既存コードの状況

- `FileIndex.rebuild()` (`Sources/polepole/FileIndex.swift:34`) は `init(project:)` (L31) からしか呼ばれていない。`ProjectsModel.fileIndex(for:)` (`Sources/polepole/ProjectsModel.swift:343-348`) が dict で 1 インスタンスを抱えっぱなしなので、プロジェクト切り替えで戻しても再構築されない
- `ProjectsModel.close()` (`ProjectsModel.swift:270` 付近) は `fileIndexes.removeValue` だけ呼ぶので、retain cycle があると `deinit` が呼ばれず stream が leak する
- 既存の `FileChangeWatcher.swift` は **単一ファイル** 用の `DispatchSource` 実装。プレビュー auto-reload 専用で、tree 再帰監視には流用できない
- `GitStatusModel.swift` は **3 秒 Timer polling**。過去 plan (`docs/plans/phase2-files.md:329`) に FSEvents 統合で**サイレントクラッシュ（exit code 6、stderr 無音、DiagnosticReports なし）**した記録があり、当時 Phase 2.5 送りにして polling に倒した経緯がある。今回も最大リスクは FSEvents wrapper 自体
- 既に `POLEPOLE_TEST_AUTO_QUICKSEARCH` env が `ProjectsModel.swift:208-212` に実装済み。VERIFY/動作確認の自動化に使える

### `git ls-files -co` の盲点 (レビュー指摘 High)

- `-c` (cached) は **git index に残っているファイル** を返す。`rm tracked.txt` した直後（`git add` で削除を記録していない状態）でも `-c` に出続ける
- 現状の `scanViaGit` (`FileIndex.swift:142-176`) はこれを `entries` に積むため、ローカルで削除しても Cmd+P にヒットし続けている (FSEvents 統合とは別の既存バグ)
- FSEvents で rebuild を発火させただけでは「削除・リネームの反映」は達成できない。`scanViaGit` に `FileManager.fileExists` チェックを足す必要あり

### FSEvents 周りの設計判断

- ベース index 構築は `git ls-files` で 1〜数秒。差分計算より **full rescan** のほうが堅いので incremental は不要
- `FSEventStreamCreate` の引数:
  - paths: project root 1 つ
  - flags: `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes`
  - `UseCFTypes` を**必ず**入れる: callback の `eventPaths` を `CFArray<CFString>` として受ける。default の `void*` → C string array は Swift 側でクラッシュしやすい (レビュー High 4)
  - latency: 1.0s
  - sinceNow: `kFSEventStreamEventIdSinceNow`
- 拾うべき特殊 flag:
  - `kFSEventStreamEventFlagMustScanSubDirs`: 取りこぼし通知 → 即 rebuild
  - `kFSEventStreamEventFlagUserDropped` / `KernelDropped`: 同上
  - `kFSEventStreamEventFlagRootChanged`: project root が消えた/移動 → rebuild してエントリ空にする
- ストーム対策 (会話で合意済み):
  - debounce 500ms。`git checkout` / `mise run build` / `node_modules` 書き換えで秒間数百イベント
  - rebuild 中に来た event は coalesce (`pendingRebuild` フラグ)
  - 直近 rebuild 終了から **2 秒以内なら追加 debounce** (rebuild 頻発防止)
- ストーム対策の責務分離 (レビュー Medium 1): `DirectoryChangeWatcher` は **debounce + filter まで**しか持たない。`minRebuildInterval` (直近 rebuild 終了からの最短間隔) は **`FileIndex` 側** に置く。watcher は完了タイミングを知らないので、知らせる経路 (`markRebuildFinished()` のような API) を増やすより、判定そのものを FileIndex に寄せた方が単純
- バッチフィルタは **per-path** (レビュー Medium 1 別件): 1 callback で複数 path が来るので、`.git/` を 1 つ含むだけで batch 全体を捨てるのは NG。各 path を個別に判定し、relevant path が 1 件でも残れば debounce を開始する
- `shouldIgnore` は **文字列 contains ではなく path components で判定** (レビュー Low): root からの相対 path を `/` で split し、各 component が `.git` / `.DS_Store` か、で判定。`.github` を `.git` 扱いする誤判定や、`node_modules/foo/bar` のような深い path の取りこぼしを避ける。`IgnoredDirectories` (node_modules / .build 等) は **watcher 側で filter しない**: gitignore に従って scanViaGit が entries から除外するので、rebuild が走っても entries は変わらず無害。watcher と scan の対象を一致させるほうが「再起動するまで出ない path」のような罠を避けられる (実装時に追加で踏み、レビュー Medium で再調整)
- 初期化順序 (レビュー Medium 2): `sinceNow` で stream を張るなら、**stream start → 初回 rebuild の順**。逆だと rebuild 中の変更を取りこぼす

### Swift 6 strict concurrency

- `FSEventStreamRef` は C 型 → `nonisolated(unsafe) private var stream: FSEventStreamRef?` で持つ
- C callback には `Unmanaged.passUnretained(self).toOpaque()` で self を渡し、callback 内で `takeUnretainedValue()` で復元
- callback → onChange は **必ず `[weak self]`** (レビュー High 3)。FileIndex が watcher を hold、watcher が self.rebuild() を strong capture すると cycle になり、`ProjectsModel.close()` の `removeValue` だけでは deinit されない
- **stop() は deinit 経路で同期的に完了する** (レビュー再 High 1): `Unmanaged.passUnretained(self)` を使う設計上、deinit から `queue.async { self.stop() }` で投げっぱなしにすると、FSEvents callback が既に解放された self を触る race がある。対策:
  - `stream: FSEventStreamRef?` と `debounce: DispatchWorkItem?` を `nonisolated(unsafe)` で持ち、**deinit から直接** `FSEventStreamStop` / `Invalidate` / `Release` / `debounce?.cancel()` を呼ぶ
  - 通常運用の `stop()` (deinit 以外から呼ぶ場合) は `queue.sync` でも良い。アプリ運用上 deinit 以外から `stop()` を呼ぶ経路は今のところ無い (close() でも removeValue だけ) ので、`stop()` 自体は内部用にして API は `deinit` 一本化でも可
  - もし `queue.sync` で deadlock リスクが懸念されるなら、専用 queue ではなく `FSEventStreamScheduleWithRunLoop` + main runloop に張る選択肢もあるが、今は試さない (Phase 0 で素直な実装が安定するか様子見)
- `final class DirectoryChangeWatcher: @unchecked Sendable` (レビュー Low: `@unchecked Sendable` は protocol conformance なので `:` で続ける)
- 配置: `Sources/polepole/` (小文字。project.yml もこちらに合わせている。レビュー Low)

## 実装計画

### Phase 0: FSEvents wrapper を単体で smoke test [AI🤖]

過去のサイレントクラッシュ事案 (`phase2-files.md:329`) を踏まえ、本体統合の前に wrapper を独立検証する。

- [ ] `Sources/polepole/DirectoryChangeWatcher.swift` を新規作成 (内容は Phase 1 で詰める)
- [ ] POC 経路を `polepoleApp` の `init` か `applicationDidFinishLaunching` に **`#if DEBUG`** で仕込む:
  1. POC 内で **先に** `try? FileManager.default.createDirectory(at: pocRoot, withIntermediateDirectories: true)` で `/tmp/polepole-fsevents-poc/` を作る (Medium 2: root が存在しない状態で stream 作成しない)
  2. その後 `DirectoryChangeWatcher(root: pocRoot) { Logger.shared.debug("[fsevents-poc] hit") }` を生成し `start()`
- [ ] `./scripts/polepole-launch.sh` で起動 → クラッシュせず安定して動くことを確認
- [ ] 別ターミナルで `touch /tmp/polepole-fsevents-poc/test.txt` → `tail -f /tmp/polepole-poc.log` にイベントが出る
- [ ] アプリを終了 → file descriptor leak がないことを `lsof` で確認
- [ ] **クラッシュした場合は撤退判断**: 過去のように silent crash なら一度コミット保護点に戻り、原因切り分け (CFRunLoop vs DispatchQueue、retain 周り、`queue.sync` の deadlock 有無) してから再挑戦
- [ ] OK だったら POC 経路と `/tmp/polepole-fsevents-poc/` のクリーンアップ、コミット

### Phase 1: DirectoryChangeWatcher 本実装 [AI🤖]

- [ ] `Sources/polepole/DirectoryChangeWatcher.swift`:
  - `final class DirectoryChangeWatcher: @unchecked Sendable`
  - init: `root: URL`, `debounceInterval: TimeInterval = 0.5`, `onChange: @Sendable () -> Void`
    - `minRebuildInterval` は **持たない** (FileIndex 側に寄せる。前提セクションの責務分離を参照)
  - 専用 serial queue で `start` / `event` / `debounce` の state を触る
  - `stream` / `debounce` は `nonisolated(unsafe)` で持ち、deinit から同期的に release できるようにする
  - `FSEventStreamSetDispatchQueue` で同じ queue にイベントを流す
  - flags は前提セクションに記載通り (`UseCFTypes` 含む)
  - C callback で `Unmanaged.fromOpaque(...).takeUnretainedValue()` → instance method へ
- [ ] イベント処理:
  - `eventPaths` を CFArray → `[String]` に変換
  - 各 path を `shouldIgnore(path:)` で個別判定 (per-path、Medium 1)
  - **判定は path components ベース** (Low): `path` を root からの relative に変換 → `/` で split → 各 component が `.git` または `.DS_Store` か、で判定。`IgnoredDirectories` は watcher 側では filter せず scan 側 (gitignore) に任せる (前提セクション参照)
  - relevant path が 1 件でも残れば debounce timer を (re)start
  - 特殊 flag (`MustScanSubDirs` / `UserDropped` / `KernelDropped` / `RootChanged`) は path 判定をスキップして即 debounce 開始
- [ ] debounce fire 時: そのまま `onChange()` を呼ぶ (minRebuildInterval の管理は FileIndex 側で行う)
- [ ] `start()`: idempotent。既に走っていれば noop
- [ ] `deinit`: queue に async せず、**直接** `FSEventStreamStop` → `Invalidate` → `Release` → `debounce?.cancel()` を実行 (High 1: callback が解放済み self を触らないようにする)
- [ ] 任意で `stop()` API も用意するが、外部からの呼び出し経路は今は無い (`ProjectsModel.close()` も dict から removeValue するだけで、deinit に任せる)

### Phase 2: FileIndex 統合 [AI🤖]

- [ ] `FileIndex` に `nonisolated(unsafe) private var watcher: DirectoryChangeWatcher?` (deinit から release できるよう)
- [ ] `FileIndex` に rebuild 制御 state を追加:
  - `private var pendingRebuild: Bool = false`
  - `private var lastRebuildFinishedAt: Date = .distantPast`
  - `private let minRebuildInterval: TimeInterval = 2.0`
- [ ] `init(project:)`:
  1. **先に** `watcher = DirectoryChangeWatcher(root: project.path) { [weak self] in ... }` を作って `start()`
  2. その後 `requestRebuild()` を呼ぶ (Medium 2: stream を張ってから初回 rebuild)
  3. callback 内は `Task { @MainActor [weak self] in self?.requestRebuild() }` で hop。`[weak self]` 必須 (High 3)
- [ ] `requestRebuild()` 新設 (rebuild の入口):
  - `isBuilding == true` なら `pendingRebuild = true` で return
  - `Date().timeIntervalSince(lastRebuildFinishedAt) < minRebuildInterval` なら、残り時間後に `requestRebuild()` を再 schedule (Medium 1: minRebuildInterval は FileIndex 側で管理)
  - それ以外は `rebuild()` を実行
- [ ] `rebuild()` の完了時:
  - `lastRebuildFinishedAt = Date()`
  - `pendingRebuild` を読んで true なら false に戻して `requestRebuild()` を再キック
- [ ] `deinit`: watcher = nil で deinit が走る (DirectoryChangeWatcher 側 deinit で同期的に stop)

### Phase 3: scanViaGit の削除済みファイル除去 [AI🤖]

レビュー High 1 の対応。FSEvents 統合とは独立した既存バグだが、本タスクで一緒に直さないと「削除が反映される」を達成できない。

- [ ] `FileIndex.scanViaGit` (`FileIndex.swift:145`) のループで、各 path について `FileManager.default.fileExists(atPath:)` を呼んで「ディスクに無い path はスキップ」
- [ ] ディレクトリ entry は「存在するファイルの親パスのみ合成」に変更 (削除されたファイルしか居ないディレクトリは合成しない)
- [ ] 50000 件カウンタは fileExists 通過後にインクリメント
- [ ] `scanViaBFS` は file system 列挙ベースなのでこの問題は無い

### Phase 4: 動作確認 [AI🤖]

レビュー High 2: 再起動 + `POLEPOLE_TEST_AUTO_QUICKSEARCH` だと初回 rebuild() で拾えてしまい FSEvents 経路を検証できない。**起動済みプロセスのまま** touch する経路を主軸にする。

検証 fixture も実 repo を弄らず tmp git repo を使う (Medium 3):

```bash
FIXTURE=$(mktemp -d)
git -C "$FIXTURE" init -q
echo "initial" > "$FIXTURE/initial.txt"
git -C "$FIXTURE" add . && git -C "$FIXTURE" commit -qm "init"
# polepole-dev/projects.json に fixture を pin
```

cleanup は `trap "rm -rf $FIXTURE; rm -rf ~/Library/Application\ Support/polepole-dev" EXIT` 等で確実に。

- [ ] `mise run build` が通る
- [ ] **debug probe env を追加** (High 2 への対応): `POLEPOLE_TEST_AUTO_FSEVENTS_PROBE=<filename>` を実装。アプリ起動後 N 秒待って:
  1. project root に `<filename>` を touch
  2. さらに M 秒待つ (debounce + rebuild 完了まで)
  3. `FileIndex.search(<filename>)` を呼んで結果件数を `Logger.shared.info("[fsevents-probe] hits=N")` で吐く
  4. これで「起動後に作成 → FSEvents 経由で rebuild → search() でヒットする」を再起動なしに検証できる
- [ ] **新規作成の反映**: 上記 fixture project を開いた状態で起動 → probe env で touch → log の `hits=` が 1 以上であることを確認
- [ ] **削除の反映** (Phase 3 の検証): fixture の `initial.txt` を `rm` → 数秒待つ → `FileIndex.search("initial")` を Logger に出す debug hook で hits=0 を確認 (probe env を「touch」だけでなく「rm」アクションも取れるよう拡張する)
- [ ] **ストーム耐性**: PolePole 自身の repo を fixture として開き、別タブで `mise run build` を走らせ、`Logger.shared.debug("[fsevents] rebuild start")` ログを `grep` でカウント。`minRebuildInterval` (2s) の縛りで秒間 1 未満に収まることを確認
- [ ] **CPU 負荷**: Activity Monitor で PolePole の CPU 使用率が rebuild 完了後にアイドルに戻ることを確認
- [ ] **fd leak**: 数プロジェクトを開閉した後 `lsof -p $(pgrep -f "PolePole Dev")` の行数が安定していることを確認
- [ ] **検証後の cleanup**: `rm -rf "$FIXTURE"` および `polepole-dev/projects.json` の fixture pin を削除
- [ ] `VERIFY.md` の Cmd+P 検証セクション (現在「FSEvents 未統合」と書かれている `VERIFY.md:853` 付近) を更新:
  - Cmd+P の自動更新確認手順を新設 (fixture + probe env を使った手順)
  - ファイルツリー (`FileTreeModel.reload`) は **本タスクの対象外** で従来通り手動 reload 依存、と明記して分離
- [ ] `docs/DEV.md` の `POLEPOLE_TEST_*` 一覧に `POLEPOLE_TEST_AUTO_QUICKSEARCH` と `POLEPOLE_TEST_AUTO_FSEVENTS_PROBE` を追記

### 動作確認 (手動) [人間👨‍💻]

- [ ] 大規模 repo (e.g. `node_modules` 込みの実プロジェクト) で `git checkout` した時に UI が固まらないか目視
- [ ] 起動済みアプリで Cmd+P を開いた状態 (overlay 表示中) で別ターミナルから `touch` → overlay 内の候補が更新されるか目視 (probe env が無い経路の最終確認)

## ログ

### 試したこと・わかったこと

#### Phase 0: `/tmp` の symlink 解決問題
- POC 起動はクラッシュなく成功。`FSEventStreamCreate` + `UseCFTypes` + Unmanaged self + deinit 同期 release で過去のサイレントクラッシュは再現せず
- ただし最初の touch がイベントとして拾えなかった。原因: `/tmp` は `/private/tmp` への symlink。FSEvents callback は resolved な `/private/tmp/...` を返すが、`URL.resolvingSymlinksInPath()` も `NSString.resolvingSymlinksInPath` も互換性配慮で `/tmp` を解決しない (`realpath(3)` だけは解決する)。`shouldIgnore` の `hasPrefix(rootPath)` が外れて全 event を捨てていた
- 対策: init で `realpath(3)` を使って rootPath を正規化
- 一般プロジェクト (`~/...`) では起きないが、防御で本実装に残す

#### Phase 4: `kFSEventStreamCreateFlagIgnoreSelf` を外す判断
- 当初 IgnoreSelf を入れたが、`POLEPOLE_TEST_AUTO_FSEVENTS_PROBE` で probe が同プロセスから `removeItem` するとイベントが落とされ、削除検知が検証できなかった
- 本番では PolePole は project ファイルを書き換えない (read-only) ので IgnoreSelf を外しても害なし。むしろ probe や将来の自プロセス由来書き込みも拾えるよう外したほうが堅い
- `write(to:atomically:)` の方は temp + rename のためか IgnoreSelf でも拾えていた

#### Phase 4: ストーム耐性の実測
- 100 ファイル連続作成 → rebuild 発火 3 回 (2 秒 minRebuildInterval で制限済み)
- FileIndex.entries が 566 → 667 (+101) に正しく増加、storm dir 削除後に 566 に復帰
- fd 推移: 92 → 98 (storm 中の一時 fd) → 92 (storm 後)。leak なし
- `mise run build` 等の長時間ストームでも秒間 1 回未満に収まる見込み

#### Phase 4: probe ordering の修正
- 初版の probe は touch を先にやって search() で FileIndex 生成 → が、FileIndex 生成は async (`Task.detached` で scan) で entries が空のままだった
- さらに FileIndex 生成と同時に watcher が始動するので、watcher 起動前の touch event は拾えない
- 修正: probe は (1) fileIndex(for:) で先に生成 (2) `isBuilding` を polling で 0 待ち (3) touch (4) wait (5) search の順に
- 結果: 新規作成 (`hits=1`) も削除 (`after-delete hits=0`) も両方 PASS

### 方針変更
- 計画では Phase 0 (POC) → Phase 1 (本実装) の 2 段だったが、Phase 0 の段階でほぼフル機能 (per-path filter / components 判定 / 特殊 flag / deinit 同期 release / debounce) を書き切れたので、Phase 1 では追加実装なし。`realpath` 対応だけ Phase 0 で追加で入った
- 計画の `minRebuildInterval` 配置は予定通り `FileIndex` 側にした (DirectoryChangeWatcher は debounce だけ)
- レビュー反映で lifetime と filter を強化:
  - `FSEventStreamContext.retain`/`release` を実装。FSEvents 側に strong ref を握らせ、in-flight callback が解放済み self を触る race を構造的に排除
  - 明示 `stop()` API を追加 (`queue.sync` で in-flight callback drain → release)。FileIndex.deinit が watcher.stop() を呼ぶ
  - `start()` を `queue.async` → `queue.sync` に変更。stream 起動 → initial rebuild の順序を保証
  - watcher の per-path filter を `IgnoredDirectories` 全部 → `.git` + `.DS_Store` のみに縮小。scan は gitignore に従うので、watcher のほうが厳しく filter すると watch/scan の対象がずれて「再起動するまで出ない path」が発生する罠を避ける。storm 抑制は debounce + minRebuildInterval だけで十分
  - `func rebuild()` を `requestRebuild` 経由に変更 (将来の手動 reload 経路から並列 scan race が起きないように)
  - VERIFY は `open -n` から binary 直叩きに変更 (env 引き継ぎの環境差を避ける)
