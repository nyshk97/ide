# Nested repo の diff / file search 対応

## 概要・やりたいこと

`~/is` のように、1 つの親ディレクトリの直下に複数の Git repository が並ぶ運用で、Cmd+D の diff overlay と Cmd+P のファイル検索から子 repository の内容も確認できるようにする。Cmd+Shift+F の全文検索も「検索ポリシーは Cmd+P と同じ」という既存方針に合わせて、同じ repository boundary を使う。

特に、親 repository の `.gitignore` に子 repository のディレクトリが入っている場合でも、子 repository 自身の diff / ファイル一覧 / 全文検索結果は見たい。親から見た Git 状態ではなく、各 repository の Git 状態として扱う。

上部の diff badge は、親 repository だけに変更がある場合は従来通り数字を出す。直下の子 repository にも変更がある場合は、ファイル数を混ぜると意味が曖昧になるため、数字ではなく accent 色の capsule に `+` を表示して「Cmd+D で見るべき nested repo の変更がある」ことだけを示す。

## 前提・わかっていること

- 現在の `DiffService.fetchDiffs(repoPath:)` は単一 repository 専用。active project の cwd で `git diff` / `git diff --staged` / `git ls-files --others` / `git ls-files --deleted` を実行している。
- 現在の `GitStatusModel` も active project 1 repository 専用。`DiffBadgeButton` は `gitStatus.statuses.count` をそのまま件数表示している。
- 現在の `FileIndex.scanViaGit(root:)` は active project の cwd で `git ls-files -co --exclude-standard -z` を実行している。親 `.gitignore` に child repository directory が入っていると、Cmd+P には child repository 内のファイルが出ない。
- 現在の `FullTextSearcher.run(query:in:)` は active project root に対して `grep -rnIH -F` を実行し、`IgnoredDirectories.grepExcludeDirArguments` で事前定義 directory を除外している。Cmd+Shift+F は Cmd+P と同じ検索ポリシーに揃える。
- 今回の探索対象は active project root と、その直下 1 階層のディレクトリだけにする。再帰探索はしない。
- 子 repository の検出では、親 repository の `.gitignore` は使わない。親から ignored になっている child directory を拾うことが今回の目的だから。
- repository 判定は `.git` が directory または file として存在することを入口にし、必要に応じて `git rev-parse --show-toplevel` で canonical root を確定する。submodule / worktree の `.git` file も落とさない。
- active project root 自身が Git repository ではなく、直下に child repository だけがあるケースでも、親直下の通常ファイルや非 repo directory は Cmd+P / Cmd+Shift+F から消してはいけない。root repo / child repo / non-git workspace remainder を分けて扱う。
- 親 repository の status / diff / file index / full-text search からは、発見した子 repository root 自体とその配下を除外して二重カウントや二重表示を避ける。相対パス判定は `rel == childRel || rel.hasPrefix(childRel + "/")` とする。
- Cmd+P では child repository のファイルを active project root からの相対パス（例: `child-repo/Sources/App.swift`）として出す。
- Cmd+Shift+F は Cmd+P と同じ検索ポリシーにする。raw `grep -r` を workspace root に直接かけるのではなく、`git ls-files -co --exclude-standard -z` 由来の Git repo ファイル集合と、non-git remainder の BFS file set を検索対象にする。
- `GitStatusModel.statuses` は FileTreeView の行バッジ用 absolute path map として維持する。diff badge 用の状態は `diffBadgeState` のような別 `@Published` に分け、`statuses` の意味を変えない。
- Cmd+D overlay では repository ごとに section 表示する。既存の `FileDiffCard(file:repoPath:)` は repoPath 依存なので、子 repository の `repoPath` を渡せば full file / image preview も正しい repository で動く。

## 実装計画

### 事前準備 [人間👨‍💻]
- [x] なし

### Phase 1: repository discovery の追加 [AI🤖]
- [x] `GitRepositoryDiscovery`（仮名）を追加し、active project root と直下 child directory から Git repository 一覧を返す。
- [x] `.git` directory / `.git` file の両方を候補にする。
- [x] `git rev-parse --show-toplevel` で repository root を正規化し、重複を除外する。
- [x] 親 `.gitignore` は使わず、FileManager の直下列挙だけで候補を作る。
- [x] `.git` 内部や package descendant には降りない。今回の探索は 1 階層限定なので再帰 walker は作らない。
- [x] discovery 結果には active project root からの `relativePath` / `isRootRepository` / child repo root の absolute path を持たせ、diff / badge / Cmd+P / Cmd+Shift+F で共有する。
- [x] workspace の構造を root repository（存在する場合）/ child repositories / non-git remainder に分けて返せる形にする。
- [x] child repository 除外 predicate は `rel == childRel || rel.hasPrefix(childRel + "/")` に統一し、status / diff / file index / full-text search で同じ判定を使う。

### Phase 2: Cmd+P file index の multi-repo 化 [AI🤖]
- [x] `FileIndex.scan(root:)` の Git repo 経路で `GitRepositoryDiscovery` を使う。
- [x] 各 repository ごとに既存の `git ls-files -co --exclude-standard -z` を cwd = repo root で実行する。
- [x] child repository の scan 結果は active project root からの相対パスに変換して `Entry.relativePath` に入れる。
- [x] root repository の scan 結果から child repository root 自体と配下を除外して、親 repo と child repo の二重表示を避ける。
- [x] active project root が非 Git で child repository が 1 つ以上ある場合も、親直下の通常ファイルや非 repo directory を BFS で scan する。child repository root は BFS から除外する。
- [x] root repository がなく child repository も 1 つも見つからない場合、または Git scan 全体が使えない場合は既存の BFS fallback を使う。
- [x] non-git remainder の BFS は既存の `IgnoredDirectories` と symlink/package descendant の扱いを維持する。
- [x] `FileIndex.scan(...)` / `scanViaGit(...)` は現状 private なので、FSEvents を起動せず unit test から呼べる pure scan helper を `internal` に切り出す。`FileIndex` の初期化・watcher 起動とは分離して Cmd+P の scan policy をテストできるようにする。
- [x] watch による rebuild は active project root 単位のまま維持し、rebuild 時に repository discovery からやり直す。直下 child repo が増減したケースも次回 rebuild で拾う。

### Phase 3: Cmd+Shift+F full-text search の multi-repo 化 [AI🤖]
- [x] `FullTextSearcher.run(query:in:)` で `GitRepositoryDiscovery` を使う。
- [x] repository が見つかる場合は、repository ごとに検索を実行する。
- [x] Git repository の検索対象は `git ls-files -co --exclude-standard -z` 由来のファイル集合に限定する。これを必須条件とし、raw `grep -r` だけで repository root を走査しない。
- [x] root repository の検索結果から child repository root 自体と配下を除外する。
- [x] child repository の検索結果は active project root からの相対 path と URL に変換して返す。
- [x] active project root が非 Git で child repository が 1 つ以上ある場合も、non-git remainder の file set を BFS で作り、その範囲を検索する。child repository root は remainder から除外する。
- [x] `grep` を使う場合は、上記 file set を batch に分けて `grep -nIH -F -- <files...>` へ渡す。workspace root への raw 再帰検索は禁止する。
- [x] grep batch はファイル数だけでなく argv byte size でも分割する。`FullTextSearcher.resultLimit` に到達したら残り batch は実行せず早期終了する。
- [x] child repo の `.gitignore` 対象ファイルが Cmd+P / Cmd+Shift+F の両方に出ないことを実装条件にする。
- [x] 検索結果上限は workspace 全体で従来の `FullTextSearcher.resultLimit` に収める。

### Phase 4: diff overlay の multi-repo 化 [AI🤖]
- [x] `RepositoryDiff`（仮名）を追加し、`repoPath` / active project からの `displayPath` / `[FileDiff]` を持たせる。
- [x] `DiffViewModel` を `[FileDiff]` から `[RepositoryDiff]` に拡張する。
- [x] root repository と child repository それぞれで既存の `DiffService.fetchDiffs(repoPath:)` を実行する。
- [x] 親 repository の `FileDiff` から、child repository root 自体と配下の path を除外する。
- [x] `DiffOverlayView` を repository section 単位の表示に変え、child repository の見出しには `displayPath` を出す。
- [x] `FileDiffCard` には各 section の `repoPath` を渡し、既存の full file / image preview 経路を保つ。

### Phase 5: diff badge の状態表現を変更 [AI🤖]
- [x] `DiffBadgeState`（仮名）を追加する。
  - [x] `none`
  - [x] `rootOnly(count: Int)`
  - [x] `includesNestedRepo`
- [x] `GitStatusModel.statuses` は FileTreeView の行バッジ用 absolute path map として維持する。
- [x] `GitStatusModel` または新しい集約モデルに、diff badge 専用の `diffBadgeState`（仮名）を別 `@Published` として追加する。
- [x] repository discovery と同じ repo 一覧を使って `diffBadgeState` を更新する。
- [x] root repository だけに変更がある場合は従来通り件数を表示する。
- [x] child repository に 1 つでも変更がある場合は、件数ではなく accent 色 capsule の `+` を表示する。
- [x] tooltip を state に合わせる。
  - [x] root only: `Open Diff (<count> files · Cmd+D)`
  - [x] nested: `Open Diff (nested repository changes · Cmd+D)`
  - [x] none: `No changes (Cmd+D to check)`
- [x] status polling では child repo ごとの正確な件数は不要。child repo は `git status --porcelain=v1 -z -uall` が空かどうかだけ見ればよい。

### Phase 6: テスト追加 [AI🤖]
- [x] repository discovery の unit test を追加する。
  - [x] active project root 自身が repo
  - [x] 直下 child directory が repo
  - [x] 2 階層下の grandchild repo は拾わない
  - [x] `.git` file の repo も拾う
  - [x] 重複 canonical root を除外する
- [x] 親 `.gitignore` で ignored になっている child repo も discovery が拾う fixture を追加する。
- [x] active project root が非 Git、直下に child repo が複数、親直下にも通常ファイルがある fixture を追加する。
- [x] Cmd+P の unit test を追加する。
  - [x] `FileIndex` の watcher を起動しない pure scan helper を直接テストする
  - [x] 親 `.gitignore` で ignored な child repo 内ファイルが検索結果に出る
  - [x] child repo 内ファイルは `child-repo/path` の relative path で出る
  - [x] 非 Git 親の通常ファイルや非 repo directory 内ファイルも検索結果に残る
  - [x] grandchild repo は拾わない
  - [x] child repo の `.gitignore` 対象ファイルは検索結果に出ない
- [x] Cmd+Shift+F の unit test を追加する。
  - [x] 親 `.gitignore` で ignored な child repo 内テキストが検索結果に出る
  - [x] root repo と child repo で同じ file が二重に出ない
  - [x] 非 Git 親の通常ファイルや非 repo directory 内テキストも検索結果に残る
  - [x] child repo の `.gitignore` 対象ファイルは検索結果に出ない
- [x] badge state の unit test を追加する。
  - [x] 変更なし
  - [x] root only 変更あり
  - [x] child repo 変更ありなら `includesNestedRepo`
- [x] parent repo から見て child repo root 自体が untracked / submodule gitlink として出るケースでも、root 側の index / diff / badge から child repo root が除外されることを確認する。
- [x] DiffService / DiffViewModel 側で、親 diff から child repo 配下が除外されることを確認する。

### Phase 7: 動作確認 [AI🤖]
- [x] `mise run build` を実行してビルドが通ることを確認する。
- [x] `VERIFY.md` の Cmd+P / Cmd+Shift+F 関連手順から該当部分だけを実行する。
- [x] `VERIFY.md` の Diff overlay 関連手順から該当部分だけを実行する。
- [x] 親 `.gitignore` で ignored にした child repo 内のファイルが Cmd+P に出る screenshot またはログを取得する。
- [x] 親 `.gitignore` で ignored にした child repo 内のテキストが Cmd+Shift+F に出る screenshot またはログを取得する。
- [x] 追加 fixture で `POLEPOLE_TEST_AUTO_OPEN_DIFF=1` を使い、child repo の diff section が overlay に出る screenshot を取得する。
- [x] child repo に変更がある場合、上部 diff badge が数字ではなく `+` になる screenshot を取得する。
- [x] root repo だけに変更がある場合、従来通り数字が出ることを確認する。

### 動作確認 [人間👨‍💻]
- [x] 必須の人間作業はなし。Cmd+D の実キー入力確認が必要な場合のみ、PolePole 内 Claude Code から `polepole-keystroke.sh` が効かない制約に従って手動確認する。

## ログ

### 試したこと・わかったこと

- 2026-06-16: `mise run build` は成功。`xcodebuild test -project polepole.xcodeproj -scheme polepole -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/polepole-build` で 25 tests / 0 failures。
- 2026-06-16: nested repo fixture で screenshot 確認済み。`/tmp/nested-quick-open.png`、`/tmp/nested-fullsearch-open.png`、`/tmp/nested-badge-plus-open.png`、`/tmp/nested-diff-overlay-open.png`、`/tmp/root-only-badge-open.png`。
- 2026-06-16: Debug app をバイナリ直叩きすると Release 側の `GHOSTTY_RESOURCES_DIR` を継承して検証 window が安定しなかった。VERIFY では `open -n "$APP" --env ...` を使う手順にした。

### 方針変更

- 2026-06-16: スコープを Cmd+D diff だけでなく Cmd+P / Cmd+Shift+F まで拡張。親 `.gitignore` に child repo が入るとファイル検索にも出ないため、`GitRepositoryDiscovery` を共通基盤にして repo boundary ごとに検索・diff・status を扱う方針に変更。
- 2026-06-16: レビュー反映。非 Git 親の通常ファイルが child repo 検出時に消えないよう non-git remainder を明記し、Cmd+Shift+F は Cmd+P と同じ file set を検索する必須方針に変更。`GitStatusModel.statuses` はツリー用に維持し、diff badge state は別 Published に分離する。
- 2026-06-16: 実装時の注意を追記。Cmd+P は FSEvents を起動しない pure scan helper を切り出して unit test 可能にし、Cmd+Shift+F の grep batch は argv byte size でも分割して resultLimit 到達時に残り batch を止める。
