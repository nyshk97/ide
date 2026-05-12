# SIMPLIFICATION_OPPORTUNITIES

2026-05-12 時点のコード棚卸し。目的は、機能をほぼ変えずに「処理を減らす」「記述量を減らす」「壊れ方を単純にする」余地を見つけること。

セキュリティ観点は広げすぎず、重要度が高いもの、または対応コストが低いものだけ載せる。

> このドキュメントは詳細リファレンス（行番号・根拠・確認手順）。実際の消化は [docs/plans/2026-05-12-code-cleanup-pass.md](./plans/2026-05-12-code-cleanup-pass.md) で追跡する。消化済みになった項目はそちらでチェックが付き、本ドキュメントの該当箇所も順次更新する。

## 調査範囲

- 要件: `REQUIREMENTS.md` section 1, 2, 3, 4, 6, 7, 8
- 設計・進捗: `docs/ARCHITECTURE.md`, `docs/DEV.md`, `docs/BACKLOG.md`, `docs/plans/phase1-terminal.md`, `docs/plans/phase2-files.md`
- 実装: `Sources/ide/*.swift` 全体、`Resources/preview/*`, `scripts/*`, `project.yml`, `Resources/IDE.entitlements`
- 観点: I/O 回数、外部コマンド起動、URL/path 比較、SwiftUI の再描画範囲、プレビューのメモリ使用、Release entitlement、ログ/一時ファイル

## 優先度

| Pri | 意味 |
|---|---|
| P0 | 先に片付けると後続の実装や検証が楽になる。処理量・堅牢性への効きも大きい |
| P1 | コスパが良い。Phase 2.5 の前後でまとめて入れると良い |
| P2 | 現状でも困りにくいが、触るタイミングが来たら整理したい |

## 要約

最も効きそうなのは次の 5 件。

1. `setActive` のたびに `projects.json` を保存しない。`lastOpenedAt` は現状ほぼ使われていないので、永続化対象から外すか、保存を遅延する。
2. `Process` 実行を共通化する。`git status` / `git check-ignore` / `grep` が同じ timeout / stdout / stderr / tool path 問題を別々に持っている。
3. Cmd+P のインデックスを Git repo では `git ls-files -co --exclude-standard -z` ベースに寄せる。独自 BFS + level ごとの `git check-ignore` より短く、`.gitignore` の再現性も高い。
4. ファイルプレビューは拡張子判定より前にサイズを見る。現状は巨大な画像/PDF が 5MB/50MB しきい値を bypass できる。
5. URL 比較・Set キーを `URL` ではなく標準化済み path 文字列に寄せる。既に `docs/DEV.md` に罠として書かれているが、ツリー/履歴/ignore 判定にまだ `URL` 比較が残っている。

## P0

### P0-1. プロジェクト切替で永続化しない

**対象**

- `Sources/ide/ProjectsModel.swift:365-375`
- `Sources/ide/ProjectsStore.swift:88-115`
- `Sources/ide/Project.swift:9`, `Sources/ide/Project.swift:61`

**現状**

`setActive(_:)` が呼ばれるたびに `lastOpenedAt = .now` を更新し、`persist()` で `projects.json` を保存する。保存時は backup rotate も走る。

ただし現在の仕様では:

- active project は再起動時に復元しない。
- temporary は以前の MRU 順ではなく、手動順序を尊重する方針に変わっている。
- MRU は `mruStack` がプロセス内で別管理している。

つまり `lastOpenedAt` は JSON を頻繁に書く理由としては弱い。

**提案**

- `setActive(_:)` は `activeProject` / workspace / unread / MRU だけ更新し、保存しない。
- `persist()` は追加・閉じる・pin/unpin・並び替え・rename/color・relocate のような「永続状態が変わる操作」だけで呼ぶ。
- `lastOpenedAt` は次のどちらかにする。
  - スキーマ互換のため decode は残し、encode から外すのは schema v2 で検討。
  - ひとまず値は残すが active 切替では更新しない。

**効果**

- プロジェクト切替のたびに JSON 書き込み + backup rotate が走らなくなる。
- `ProjectsStore` の backup が「本当に設定が変わった履歴」だけになる。
- `setActive` の責務が軽くなり、missing project クリック抑止なども入れやすくなる。

**確認**

- `VERIFY.md` section 13, 14, 16, 17, 30 のうち、projects.json を読む/書くもの。
- Ctrl+M / サイドバークリックで `projects.json` の mtime が変わらないこと。

### P0-2. 外部コマンド実行を `ProcessRunner` に寄せる

**対象**

- `Sources/ide/GitStatusModel.swift:91-117`
- `Sources/ide/GitIgnoreChecker.swift:10-62`
- `Sources/ide/FullTextSearcher.swift:22-59`
- `Sources/ide/FilePreviewView.swift:206-218`

**現状**

`Process` の組み立て、tool path 探索、timeout、stdout 読み取りが複数箇所に分散している。具体的な問題:

- `stderr` を `Pipe` にしているが読んでいない（`FullTextSearcher` / `GitStatusModel` / `GitIgnoreChecker`）。外部コマンドが大量に stderr を出すと pipe バッファ（macOS で 64KB）が詰まり、コマンドが stderr への write でブロックして待ち続ける。`grep -rnIH` を権限のないディレクトリ混じりの大きい木に投げると現実的に起こりうる。
- `GitIgnoreChecker.check` は `stdin.fileHandleForWriting.write(inputData)` を**同期で全部書いてから** stdout を読む。投入パスが多くて `git check-ignore` の出力が pipe バッファを超えると、git が stdout への write でブロック → こちらの stdin write もブロックでデッドロックする（古典的な stdin↔stdout 同時バッファ詰まり）。
- `locateGit()` が `GitStatusModel` と `GitIgnoreChecker` で別実装になっていて、候補パスの優先順位すら違う（`/usr/bin/git` 優先 vs `/opt/homebrew/bin/git` 優先）。

**提案**

`Sources/ide/ProcessRunner.swift` のような小さい共通部品に集約する。

- `BinaryLocator.git`, `BinaryLocator.grep`, `BinaryLocator.cursor`
- `run(executable:arguments:cwd:stdin:timeout:maxStdoutBytes:)`
- stdout/stderr の両方を drain
- stdin への供給は別 queue / writabilityHandler に分け、stdout drain と同時並行にする
- timeout 時は terminate し、必要なら kill まで進める
- `Result` に `exitCode`, `timedOut`, `stdout`, `stderr` を持たせる

**効果**

- 要件 8.1 の「argv 配列で起動」を 1 箇所で守れる。
- `locateGit()` の重複を消せる。
- timeout・stderr 詰まり・stdin↔stdout デッドロックの扱いが 1 箇所に揃う。
- grep/ripgrep 移行時の差分が小さくなる。

**確認**

- `git` が無い/壊れている状態で固まらず空表示または toast になること。
- 大量 stderr を出すダミーコマンドでも timeout で戻ること。
- `VERIFY.md` section 7, 10, 11。

### P0-3. 巨大画像/PDF をサイズしきい値の対象にする

**対象**

- `Sources/ide/FilePreviewModel.swift:90-105`
- `Sources/ide/FilePreviewView.swift:134-144`

**現状**

拡張子が画像/PDF の場合、サイズ確認より前に `.image` / `.pdf` を返す。そのため 50MB 超の画像や PDF でも `NSImage(contentsOf:)` / `PDFDocument(url:)` に進める。

**提案**

- `fileExists` の直後に `attributesOfItem` で size を見る。
- 画像/PDF/テキストすべてに `warnSize` / `externalSize` を適用する。
- `forceLoadLarge` のときも `Data(contentsOf:)` を View の body から直接呼ばず、`classifyAndApply` と同じ async 経路で読む。

**効果**

- 大きなプレビューで UI が固まる可能性を減らせる。
- 要件 6.4 のサイズしきい値に素直に合う。
- 読み込み経路が「分類 Task で読む」に揃う。

**確認**

- `VERIFY.md` section 23 の大きいファイル確認。
- 5MB 超画像/PDF が確認 UI になること、50MB 超が外部誘導になること。

### P0-4. `URL` を状態キーにしない `FilePathKey` を導入する

**対象**

- `Sources/ide/FileTreeModel.swift:16-25`（`expanded` / `scannedDirs`）, `Sources/ide/FileTreeModel.swift:62-88`（`findNode`）
- `Sources/ide/FilePreviewModel.swift:16-28`（preview history）
- `Sources/ide/GitIgnoreChecker.swift:65-87`（`check` の戻り値 `Set<URL>`）
- `Sources/ide/FileIndex.swift:25`（`recents: [URL: Date]`）, `Sources/ide/FileIndex.swift:103-105`（`recordOpen`）

**現状**

一部では `URL.standardizedFileURL.path` を使っているが、`expanded: Set<URL>`, `scannedDirs: Set<URL>`, preview history, ignore 判定の `Set<URL>` などには `URL` 比較が残っている。`docs/DEV.md` でも「URL の == は scheme/baseURL の差で一致しないことがある」と既知の罠になっている。

**提案**

小さな型を 1 つ作る。

```swift
struct FilePathKey: Hashable, Codable {
    let path: String
    init(_ url: URL) {
        self.path = url.standardizedFileURL.path
    }
}
```

使いどころ:

- `expanded`, `scannedDirs`, `selectedURL` の比較
- `FilePreviewModel.history` の重複判定
- `GitIgnoreChecker.check` の戻り値
- `FileIndex.recents`

**効果**

- URL 比較のバラつきを消せる。
- `GitIgnoreChecker.check` の `ignored.contains(node.url)` のような微妙な不一致リスクが減る。
- path 文字列で UI 表示や相対パス計算も組み立てやすくなる。

**確認**

- `VERIFY.md` section 8, 9, 10。
- symlink / standardized path / file URL の混在でも選択状態・履歴・ignore 表示が崩れないこと。

## P1

### P1-1. Cmd+P の Git repo 走査を `git ls-files` に寄せる

**対象**

- `Sources/ide/FileIndex.swift:137-205`
- `Sources/ide/GitIgnoreChecker.swift`

**現状**

Cmd+P インデックスは BFS でディレクトリを辿り、各階層のディレクトリ群を `git check-ignore` にかけている。コメントにもある通り、**ディレクトリ単位の ignore しか見ておらず、ファイル単位の ignore は意図的に無視**している（gitignore された `.env` 等は Cmd+P にヒットする、という現状仕様）。

**提案**

Git repo ではまず次を使う。

```bash
git ls-files -co --exclude-standard -z
```

- tracked + untracked + ignored 除外を Git に任せる。
- ディレクトリ entry はファイルパスから親ディレクトリを合成する。
- 空ディレクトリは Git 的に出ないが、Cmd+P で空ディレクトリを開く価値は低い。必要なら FileManager fallback に任せる。
- `includeIgnored=true` のときだけ現行 BFS または別 fallback を使う。
- 非 Git repo は現行 scan を残す。

**挙動の変化（要注意）**

`git ls-files -co --exclude-standard` は**ファイル単位の ignore も効く**ので、gitignore された `.env` のようなファイルは Cmd+P に出なくなる。現状の「ファイル単位 ignore は無視」は意図的な簡略化だったが、要件 6.1（`.gitignore` 対象はデフォルト除外）にはむしろ忠実になる。とはいえ既存の体感は変わるので、`includeIgnored=true` で従来通り全部出るようにしておくこと（fallback の現行 BFS でカバーできる）。

**効果**

- 独自 BFS と ignore 判定の大半を消せる。
- `.gitignore` の再現性が Git と一致する（ファイル単位も含む）。
- 大規模 repo での初回インデックスが軽くなる可能性が高い。

**確認**

- `VERIFY.md` section 25。
- `.gitignore` 対象ファイルが通常は出ず、`includeIgnored` で出ること。
- 隠しファイルは要件通り含まれること。

### P1-2. 検索・ツリーの除外ポリシーを 1 箇所に寄せる

**対象**

- `Sources/ide/FileIndex.swift:150-153`（`alwaysSkipDirNames` = `.git` / `cheapSkipDirNames` = `node_modules` `DerivedData` `.build`）
- `Sources/ide/FullTextSearcher.swift:31-40`（`--exclude-dir=.git/node_modules/DerivedData/.build/.refs`）
- `Sources/ide/FileTreeModel.swift:94-130`（`scanChildren` — dir スキップ無し）, `Sources/ide/FileTreeModel.swift:84-90`（`applyIgnored`）

**現状**

`.git`, `node_modules`, `DerivedData`, `.build`, `.refs` などの扱いが複数箇所で微妙に分かれている。特に:

- `FileIndex` は `.git` を常時スキップ、`node_modules` 等は `includeIgnored=false` のときだけスキップ、それ以外は `git check-ignore` 任せ。
- `FullTextSearcher` は `.refs` まで含めて 5 個を `--exclude-dir` でハードコード（`git check-ignore` は使わない）。
- `FileTreeModel` は**ディレクトリのスキップ自体をしていない**（`.git` も木に出る）。lazy 展開頼みで「展開しなければ中は見ない」だけ。`applyIgnored` は `git check-ignore` の結果で薄表示フラグを立てるが、これは隠す処理ではない。

**提案**

`SearchPolicy` / `ProjectFilePolicy` のような小さな enum にまとめる。

- `alwaysSkipDirs`
- `cheapIgnoredDirNames`
- `grepExcludeArgs`
- `shouldDescend(url:)`

**効果**

- Cmd+P / Cmd+Shift+F / ツリーの挙動差分を見つけやすくなる。
- Phase 2.5 の ripgrep バンドリング時に glob を作りやすい。
- 「隠しファイルは含む、ignore 対象はデフォルト除外」という要件 6 / 7 を 1 箇所で説明できる。

### P1-3. 全文検索は stdout 全読みではなく streaming / early stop にする

**対象**

- `Sources/ide/FullTextSearcher.swift:43-59`
- `Sources/ide/FullTextSearcher.swift:62-77`

**現状**

grep の stdout をすべて読み終わってから parse し、parse 側で 1000 件に切っている。結果上限は UI 表示上は守られるが、grep 側は 1000 件を超えても出力し続ける。

**提案**

短期:

- `ProcessRunner` に `maxStdoutBytes` を持たせ、上限を超えたら terminate。
- stdout を行単位で処理し、1000 件に達したら terminate。

Phase 2.5:

- bundled `rg` へ移行し、`--hidden`, `--glob`, `--fixed-strings`, `--max-count` などを policy から組み立てる。

**効果**

- 大量ヒット時のメモリと待ち時間を減らせる。
- 「1000 件上限」が実処理にも効く。

### P1-4. missing project を active にしない

**対象**

- `Sources/ide/Project.swift:31-35`
- `Sources/ide/LeftSidebarView.swift:108-159`
- `Sources/ide/ProjectsModel.swift:174-185`, `Sources/ide/ProjectsModel.swift:365-380`

**現状**

View の body で `project.isMissing` が毎回 FileManager を叩き、missing でも `projects.setActive(project)` が呼ばれる。`setActive` は workspace を作るため、存在しない cwd で terminal 起動に進む可能性がある。

**提案**

- `ProjectsModel` に `availabilityByProjectID: [UUID: ProjectAvailability]` を持つ。
- 起動時、アプリ active 復帰時、手動 reload、relocate 後にだけ existence を更新する。
- missing row click は `ErrorBus.notify` して workspace を作らない。
- 中央ペインには active ではなく selected/missing details を出したい場合だけ別 state を持つ。

**効果**

- 要件 2「クリックしても開けない」に合う。
- SwiftUI 再描画ごとの stat を減らせる。
- missing project からの ghostty 起動失敗経路を消せる。

### P1-5. `PocLog` を撤去して `Logger` に一本化する

**対象**

- `Sources/ide/Logging.swift:3-25`
- `Sources/ide/Logger.swift:60-79`
- `docs/BACKLOG.md` の既知課題

**現状**

`PocLog.write` は `/tmp/ide-poc.log` に書き、stderr にも書き、さらに `Logger.shared.debug` を呼ぶ。`Logger.write` も stderr に書くので、PocLog 経由のログは stderr へ二重に出る。

**提案**

- `PocLog.write` call site を `Logger.shared.debug` に置換する。
- VERIFY 用に `/tmp/ide-poc.log` が便利なら、Debug ビルド限定で `Logger` の mirror sink として実装する。
- `PocLog.reset()` は Debug mirror だけ初期化する。

**効果**

- ログ経路が 1 本になる。
- stderr 二重出力が消える。
- Phase 2.5 の既知課題をひとつ閉じられる。

### P1-6. Markdown ローカルリンクの開ける範囲を制限する

**対象**

- `Sources/ide/PreviewWebView.swift:139-157`
- `Sources/ide/PreviewWebView.swift:196-209`

**現状**

Markdown 内の file URL は `onNavigateToFile?(url)` でそのままプレビューに渡される。クリック操作は必要だが、プロジェクト外のローカルファイルも開ける。

**提案**

- `PreviewPayload` に `allowedRoot` または `projectRoot` を持たせる。
- file URL は `allowedRoot` 配下のみ同一プレビューで開く。
- root 外は toast で「プロジェクト外リンクはコピーしました」にするか、確認を挟む。

**効果**

- untrusted Markdown を見たときのローカルファイル露出リスクを下げられる。
- Dropbox / 外部同期配下の Markdown でも挙動が読みやすい。

### P1-7. Release entitlement を最小化する

**対象**

- `Resources/IDE.entitlements:11-18`

**現状**

Release に `com.apple.security.automation.apple-events` が入っているが、アプリ本体で Apple Events を送る実装は見当たらない。`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation` は libghostty 由来の可能性があるので要検証。

**提案**

- まず `automation.apple-events` を外して Release build + notarize + 実機起動を確認する。
- 残りの hardened runtime 例外は 1 つずつ外して ghostty 起動可否を確認し、必要なものだけ残す。

**効果**

- セキュリティ権限の説明責任が軽くなる。
- 配布物としての攻撃面を少し減らせる。

**確認**

- Release configuration のみ。Debug では entitlements を使わない。
- `scripts/build.sh` と実機起動、ターミナル描画、IME、clipboard。

### P1-8. `openInTerminal` の暫定 pasteboard コマンドを安全にする

**対象**

- `Sources/ide/FileTreeView.swift:254-268`
- `Sources/ide/ClipboardSupport.swift:163-174`

**現状**

「ターミナルで開く」は active tab を取っているが実際には使わず、`cd \(dir.path)\n` を pasteboard に入れている。スペースはまだ shell 的に壊れ、改行などを含むパスでは危険。

**提案**

短期:

- `ShellEscaper` を `ClipboardSupport` から独立させ、`cd \(shellEscape(dir.path))\n` にする。
- unused な `workspace` / `pane` / `tab` 取得は削る。

中期:

- active surface に `ghostty_surface_text` で直接 `cd -- <escaped path>\n` を送るか、新規タブ cwd 指定にする。

**効果**

- 少ない変更でパス事故を減らせる。
- 暫定実装のコメント量と unused フックを減らせる。

### P1-9. クリップボード画像の一時ファイルに TTL を持たせる

**対象**

- `Sources/ide/ClipboardSupport.swift:103-120`

**現状**

画像 paste 時に `FileManager.default.temporaryDirectory`（= `$TMPDIR`、非サンドボックスアプリだと `/var/folders/<…>/T/`。`/tmp/` ではない）配下の `clipboard-<timestamp>-<uuid8>.<ext>` へ書くが、削除経路がない。画像には個人情報が入りやすい。コード/コメント側にも「`/tmp/clipboard-...`」という不正確な表現が残っているので合わせて直す。

**提案**

- `~/Library/Caches/{ide,ide-dev}/clipboard/` へ保存する。
- 起動時に 1 日以上古いものを削除する。
- `AppPaths` に `cacheDirectory` を追加し、Release/Debug を分離する。

**効果**

- 一時ディレクトリに残る画像を管理できる。
- セキュリティ改善としてコストが低い。

## P2

### P2-1. `ProjectsModel` の責務を分ける

**対象**

- `Sources/ide/ProjectsModel.swift` 全体

**現状**

プロジェクト一覧、workspace registry、file tree registry、preview registry、Cmd+P、Cmd+Shift+F、MRU、test env 初期化を 1 singleton が持っている。現時点で 561 行あり、状態追加がここに集まりやすい。

**提案**

すぐ分割する必要はないが、次に触るなら次の単位が自然。

- `ProjectListStore`: pinned/temporary, persist, move, pin
- `WorkspaceRegistry`: workspaces, unread aggregation
- `SearchOverlayState`: quick/full search
- `ProjectTestBootstrap`: `IDE_TEST_*`

**効果**

- SwiftUI の再描画範囲を小さくしやすい。
- test env と本機能が混ざりにくくなる。
- Phase 2.5 の watcher を足す場所が明確になる。

### P2-2. Foreground process polling の対象を絞る

**対象**

- `Sources/ide/GhosttyManager.swift:78-105`
- `Sources/ide/RootLayoutView.swift:96-100`
- `Sources/ide/TabsView.swift:17-21`

**現状**

開いた workspace / tab は ZStack で生かし続ける。これは要件 2 / 4 に合っている。一方、foreground process は全 surface を 500ms ごとに poll する。

**提案**

- タブ数が増えてからでよいが、AI バッジ対象になりうるタブだけ頻度を上げ、shell 判定済み idle tab は 2-3 秒間隔に落とす。
- active tab は現状維持、background は低頻度にする。

**効果**

- 多タブ dogfooding 時の libproc 呼び出しを減らせる。
- 要件の「ターミナルは生かす」は維持できる。

### P2-3. ファイルツリーの node 探索を辞書化する

**対象**

- `Sources/ide/FileTreeModel.swift:62-81`

**現状**

展開時に `findNode` が root から再帰探索する。通常は問題ないが、展開済み node が増えるほど O(N) になる。

**提案**

- `nodeByPath: [FilePathKey: FileNode]` を scan 時に更新する。
- `expanded` / `scannedDirs` も `FilePathKey` で持つ。

**効果**

- P0-4 の `FilePathKey` 導入と合わせると自然に短くなる。
- 大きい tree の展開が読みやすくなる。

### P2-4. プレビューの WebView singleton 方針を明文化する

**対象**

- `Sources/ide/PreviewWebView.swift:20-27`
- `Sources/ide/PreviewWebView.swift:196-214`

**現状**

WKWebView は singleton で高速化している。中央ペインは active project 1 つだけなので成立しているが、将来プレビューを複数同時表示すると `onNavigateToFile` が最後の caller で上書きされる。

**提案**

- 現状維持でよい。
- `PreviewWebController` のコメントに「同時に 1 プレビューだけ」という前提を明記する。
- 将来 multi preview を入れる時は project/view ごとの controller に戻す。

**効果**

- 今は余計な抽象化をしない判断を残せる。

### P2-5. `git status` の使われない `ignored` バッジを消す

**対象**

- `Sources/ide/GitStatusModel.swift:92-98`（`runGitStatus` の引数）
- `Sources/ide/GitStatusModel.swift:22-46`（`Badge` enum）, `Sources/ide/GitStatusModel.swift:150-163`（`badgeFromXY`）

**現状**

`git status --porcelain=v1 -z -uall` は `--ignored` を渡していないので、出力に `!!` が出ることはない。にもかかわらず `Badge.ignored`（`!` / グレー）と `badgeFromXY` の `"!"` 分岐が残っていて、実行されないコードになっている。

**提案**

- `Badge.ignored` と `badgeFromXY` の `"!"` 分岐を消す。
- ignore 状態をツリーに出したいなら `git status --ignored` を足すのではなく、既存の `GitIgnoreChecker`（→ `FileTreeModel.applyIgnored` の薄表示）に寄せる。

**効果**

- 「出るはずのバッジが出ない」混乱の元を 1 つ消せる。
- `git status` の出力フォーマットへの依存が少し減る。

## 実装順のおすすめ

1. `ProcessRunner` + `BinaryLocator` を作る。
2. `FullTextSearcher`, `GitStatusModel`, `GitIgnoreChecker` を ProcessRunner に載せ替える。
3. `setActive` から永続化を外し、`lastOpenedAt` の扱いを整理する。
4. `FilePathKey` を導入し、tree / preview / ignore / recents の比較を置き換える。
5. プレビューのサイズ判定を先頭へ移す。
6. `git ls-files` ベースの Cmd+P scan を Git repo にだけ入れる。
7. セキュリティ quick wins: Apple Events entitlement, Markdown root 制限, `cd` の shell escape, clipboard image TTL。
8. `PocLog` を `Logger` へ統合する。

## やらなくてよさそうなこと

- すぐに `ProjectsModel` を大分割すること。先に P0/P1 を入れる方が効果が大きい。
- プレビューを複数 WebView に戻すこと。現状の singleton は初回表示速度のために妥当。
- FSEvents を今すぐ再挑戦すること。これは Phase 2.5 の大物で、今回の「シンプル化」とは別タスクとして扱う方がよい。
- セキュリティ強化として外部 URL クリック全体を厳しくすること。ターミナル URL は http/https のみで要件に沿っており、優先度は高くない。
