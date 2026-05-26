# 空状態UI改善 + プロジェクトインポート機能

## 概要・やりたいこと

インストール直後やプロジェクトを全削除して0件になった時、現状の中央ペインは「Add a folder to get started」とだけ書かれている。何をすればいいか分かりづらい上、cmux / tmuxinator / VS Code 等から乗り換えてきたユーザーが既存のプロジェクト一覧を素早く取り込む手段もない。

- **目的1**: 0件状態のハブ画面を、最初の一歩 (`Choose folder`)・既存資産の取り込み (`Import projects`)・使い方の確認 (`Guide`) の3アフォーダンスで案内する画面に作り替える
- **目的2**: 慣習ディレクトリ / cmux / tmuxinator / VS Code・Cursor から既存プロジェクトを発見し、重複を排除した上で一括インポートできるようにする (cmux の `isPinned` / `customTitle` は引き継ぐ)
- **目的3**: 0件状態のときだけ非同期で background scan して `Import projects (N)` のバッジで気付かせる
- **目的4**: 既存ユーザー (1件以上ある状態) からも Settings の `Import` タブから同じ機能に到達できる

## 前提・わかっていること

### 現状コード

- 中央ペインの空状態: `Sources/polepole/CenterPaneView.swift:49-62` (`Add a folder to get started`)
- サイドバーの空状態テキスト: `Sources/polepole/LeftSidebarView.swift:68` (`Add a project`)
- プロジェクト追加経路: `Sources/polepole/LeftSidebarView.swift:49-61` の「+」ボタン → `NSOpenPanel` → `ProjectsModel.addTemporary(path:)`
- **`ProjectsModel` の重要事実**: `pinned` / `temporary` は `private(set) @Published`。`addTemporary(path:)` だけが「重複判定 → 追加 → persist → active 化」をまとめている。直接 store に書くと `@Published` が発火せず UI 更新も `activeProject` 同期も漏れる (`Sources/polepole/ProjectsModel.swift:14, 240`)
- ProjectsStore のスキーマ: `Sources/polepole/ProjectsStore.swift:11-14`、`schemaVersion: 1`、`projects: [{id, path, displayName, isPinned, lastOpenedAt, colorKey?}]`
- 既存重複判定 `ProjectsModel.project(at:)` は path 文字列の単純比較 (`Sources/polepole/ProjectsModel.swift:718`)。canonicalize 入れるなら同じ normalizer に寄せる必要あり
- 初回起動フラグは未実装。0件状態は `projects.load()` が空配列を返した時に分岐表示するだけ
- Debug ビルドは `~/Library/Application Support/polepole-dev/`、Release は `polepole/` に保存
- `project.yml` の `resources:` は `Resources/*` だけ。test target は未定義 (`project.yml:31, 35`)
- `backend/public/guide.html` はアプリバンドルに同梱されておらず、`/styles.css` の絶対パスを参照しているのでファイル URL では CSS が壊れる
- `PreviewWebController` は singleton (流用禁止、Guide には使わない)

### インポート source の構造

| Source | パス | 取れるもの |
|---|---|---|
| 慣習ディレクトリ scan | `~/ghq` `~/src` `~/dev` `~/Projects` `~/Code` | `.git` のあるディレクトリ列挙 (深さ上限あり) |
| cmux | `~/Library/Application Support/cmux/session-com.cmuxterm.app.json` | `windows[].tabManager.workspaces[]` の `currentDirectory` / `customTitle` / `isPinned` |
| tmuxinator | `~/.tmuxinator/*.yml` | YAML の `root:` フィールド (`~` 展開・quote/comment 除去・ERB スキップ・存在確認) |
| VS Code / Cursor | `~/Library/Application Support/Code/User/globalStorage/storage.json` および `Cursor/` | `openedPathsList` の workspace パス + 最終 access 順序 |

cmux の `session-*.json` 構造はユーザーマシン (16 workspaces) で実測確認済み。ユーザー本人が canonical user なのでテスト材料になる。

### 設計の決定事項

- **画面構成**: 中央ペインを統一ハブに。初回も 0件復帰も同じ画面 (Welcome 専用画面は作らない)
- **既存ユーザー導線**: `Settings` ウィンドウに新規 `Import` タブを追加し、同じ ImportSheet 相当の View を `NavigationStack` 内で再利用
- **canonical key と保存 path を分離**: `ImportCandidate` には `canonicalKey: String` (= `URL(fileURLWithPath:).resolvingSymlinksInPath().standardizedFileURL.path`、dedupe 用) と `preferredPath: String` (= source が返した raw path、`~` だけ展開済み) を両方持つ。**保存は `preferredPath`** (symlink 経由で運用してたユーザーの path をそのまま尊重)、**重複判定は `canonicalKey`**。既存 `ProjectsModel.project(at:)` も同じ `PathNormalizer.canonicalKey(_:)` に寄せて全体の dedupe ルールを統一
- **重複の表示**: 1パス1行 + source バッジ複数表示 (`cmux ghq` 等)。複数 source = 確度高 → デフォルト選択 ON
- **scan タイミング**: 0件状態のハブ画面が表示されたタイミングで非同期 scan。1件以上ある時は EmptyHubView を出さないので自動 scan も走らない。Settings の Import タブを開いたときは押下時 scan (明示的に開いた = 待っている前提)
- **scan 進捗 UX**: ボタン初期 `[ Import projects... ]` (スピナー、淡め) → 結果出たら `[ Import projects (28) ]` に差し替え
- **未インストール source**: ファイルが無いだけなので静かにスキップ。エラー UI 不要
- **並び順**: 取り込み時刻順 (末尾追加)。bulk import でも順番を保って末尾追加
- **既存登録済み**: import 候補から除外し折りたたみで `Already in PolePole (6 hidden)` 表示。展開可
- **cmux からの引き継ぎ**: `isPinned == true` は PolePole 側も pin、`customTitle` が folder 名と異なれば `displayName` に採用
- **デフォルト選択スコア**:
  - cmux に居る: +2 / cmux pinned: +2 / 慣習dir scan で見つかった: +1 / tmuxinator: +1 / VS Code 30日以内: +1 / VS Code 90日以上前: -1
  - `score >= 2` でデフォルト ON
- **クイック選択ボタン**: `All` / `None` / `cmux pinned only`
- **使い方ガイド**: 外部ブラウザで `https://polepole.dev/guide` を開く (`NSWorkspace.shared.open`)。bundle 同梱はせず保守を一本化
- **ProjectsModel bulk API**: `ProjectsModel.importProjects(_ candidates: [ImportPayload])` を追加し、「pin/temp への振り分け・dedup・persist・初回 active 化」をすべてここで完結させる。Import sheet は ProjectsStore を直接いじらない

### 設計しない (今回はやらない)

- zsh history からの `cd <path>` 頻度抽出
- tmux-resurrect (`~/.tmux/resurrect/last`) 取り込み
- 慣習ディレクトリの設定可能化 (`~/ghq` 等の追加 UI)。設定で持つなら `AppPaths.applicationSupportDirectory` 配下に置くが、当面は固定 5 パスで様子見
- 起動時 background scan (0件状態のみに限定)
- 取り込み先 source の自動再同期 (一度取り込んだら以後の cmux 変更は追わない)
- Guide のオフライン同梱 (外部ブラウザ運用に統一)

## 実装計画

### 事前準備 [人間👨‍💻]
- [ ] (なし — 既存環境で完結する)

### Phase 1: テスト基盤と ProjectsModel 拡張 [AI🤖]
- [ ] `project.yml` に `polepoleTests` test target を追加 (`type: bundle.unit-test`、`platform: macOS`、`scheme: PolePole Dev` 内に test action を組み込み)
- [ ] XcodeGen 再生成 (`xcodegen generate`) と `mise run build` が通ることの確認
- [ ] `Sources/polepole/Import/PathNormalizer.swift` を新規作成
  - `static func canonicalKey(_ path: String) -> String?` (`resolvingSymlinksInPath().standardizedFileURL.path`、存在しない or 空文字は nil)
  - `static func expandTilde(_ path: String) -> String` (`(path as NSString).expandingTildeInPath`)
- [ ] `ProjectsModel.project(at:)` の path 比較を `PathNormalizer.canonicalKey` ベースに置き換え (`Sources/polepole/ProjectsModel.swift:718` 周辺)。既存ユニットテスト・スナップショットがあれば差分確認
- [ ] `Sources/polepole/Import/ImportTypes.swift` で共通型を定義
  - `struct DiscoveredProject { canonicalKey: String; preferredPath: String; displayName: String?; isPinned: Bool; lastAccessAt: Date?; sourceId: String }`
  - `struct ImportCandidate { canonicalKey: String; preferredPath: String; displayName: String?; isPinned: Bool; sources: [String]; lastAccessAt: Date?; defaultSelected: Bool }`
  - `struct ImportPayload { preferredPath: String; displayName: String?; isPinned: Bool }`
- [ ] `ProjectsModel.importProjects(_ payloads: [ImportPayload]) -> [Project]` を追加
  - `PathNormalizer.canonicalKey` で既存 path と被るものはスキップ
  - `isPinned == true` は pinned 配列の末尾に、false は temporary 配列の末尾に振り分け
  - `persist()` を1回だけ呼ぶ
  - 既存 active project が nil の時のみ最初の追加項目を active 化
  - 返り値で実際に追加された Project を返す (sheet 側で count 表示に使う)

### Phase 2: ImportSource プロトコルと4つの source 実装 [AI🤖]
- [ ] `Sources/polepole/Import/ImportSource.swift`
  - `protocol ImportSource { var id: String { get }; var displayName: String { get }; func discover() async -> [DiscoveredProject] }`
- [ ] `Sources/polepole/Import/ImportAggregator.swift`
  - 複数 source の `DiscoveredProject` を canonical key で merge し `ImportCandidate` を組み立て
  - 既存 `ProjectsModel.pinned + temporary` の path と被るものを `alreadyImported` に分離 (こちらも `PathNormalizer.canonicalKey`)
  - デフォルト選択スコア式を実装 (cmux pinned 強め)
- [ ] `ConventionalDirScanSource`
  - 探索ルート: `~/ghq` `~/src` `~/dev` `~/Projects` `~/Code` (固定)
  - 各 root を BFS、最大深さ 4。`.git` がある dir を見つけたらそこで打ち止め (それより下は降りない)
  - source 全体に 3 秒の timeout (超過したらそれまでの結果を返す)
  - **`fixtureRoots: [URL]? = nil` を init で受け取れるようにし、テスト時は fixture ツリーを差し込めるようにする**
- [ ] `CmuxSessionSource`
  - `~/Library/Application Support/cmux/session-com.cmuxterm.app.json` を Codable で読む
  - `windows[].tabManager.workspaces[]` から `currentDirectory` / `customTitle` / `isPinned` を抽出
  - ファイル無ければ空配列
  - **`fixturePath: URL? = nil` を init で受け取り可能に**
- [ ] `TmuxinatorSource`
  - `~/.tmuxinator/*.yml` を列挙
  - 各 YAML を行ベースで読み、`^\s*root:\s*(.+)$` をマッチ。マッチ後に
    - quote (`'...'` / `"..."`) を剥がす
    - `#` 以降のコメントを切る
    - 行が `<%= ... %>` を含むなら ERB と見なしてスキップ
    - `~` 展開
    - 環境変数 (`$HOME` 等) は素朴に `expandingTildeInPath` のみ。`$VAR` 形式は今回は展開しない (失敗時スキップ)
    - 最後に `FileManager.default.fileExists(atPath:)` で実在確認、無ければ捨てる
  - **`fixtureRoot: URL? = nil` を init で受け取り可能に**
- [ ] `VSCodeRecentSource`
  - `~/Library/Application Support/{Code,Cursor}/User/globalStorage/storage.json` を JSONDecoder で読む
  - `openedPathsList.entries[].folderUri` の `file://` を path に変換
  - 配列順を最終 access 順とみなして `lastAccessAt` を `Date()` から逆算する (storage に明示的なタイムスタンプは無いので、新しいものから 1 日ずつ古くする近似)
  - **`fixturePaths: [URL]? = nil` を init で受け取り可能に**
- [ ] `polepoleTests/ImportSourceTests.swift` を追加
  - `polepoleTests/Fixtures/import/conventional/...` に偽 git リポジトリを置いて scan を検証
  - `Fixtures/import/cmux/session.json` に最小限の cmux session を置く (workspace 3件、うち 1 件 pin)
  - `Fixtures/import/tmuxinator/{quoted,commented,erb,nonexistent,plain}.yml` を置いて root: 解析の edge case を検証
  - `Fixtures/import/vscode/storage.json` も同様
  - `ImportAggregator` の merge / dedup / `alreadyImported` 分離 / スコア式を検証
- [ ] `POLEPOLE_TEST_IMPORT_FIXTURE=<dir>` の env を読み、各 source の本番経路でも fixture root に差し替えできるようにする (Phase 5/動作確認の screenshot 用)。`docs/DEV.md` のフラグ表に追記

### Phase 3: EmptyHubView (中央ペイン統一ハブ) [AI🤖]
- [ ] `Sources/polepole/EmptyHubView.swift` を新規作成
  - 上部: PolePole ロゴ + 「Get started」見出し
  - 中段: `[ Choose a folder... ]` プライマリボタン → `NSOpenPanel` (既存 `LeftSidebarView` のロジックを共通化して呼ぶ)
  - 区切り: `── or ──`
  - `[ Import projects... ]` ボタン (初期は disabled + スピナー、scan 完了で件数を載せて enabled に。0件なら disabled のまま `No projects found to import`)
  - 下部: `📖 How to use PolePole` リンク → `NSWorkspace.shared.open(URL(string: "https://polepole.dev/guide")!)`
- [ ] `CenterPaneView.swift:49-62` の現行空状態分岐を `EmptyHubView` に差し替え
- [ ] `EmptyHubView` 表示時に `Task { await scanner.discover() }` を起動。`@StateObject` でスキャナの結果と loading 状態をバインド
- [ ] `POLEPOLE_TEST_AUTO_EMPTY_HUB=1` の env を読み、既存プロジェクトがあっても強制的に EmptyHub を出すフラグを追加 (`docs/DEV.md` 追記)
- [ ] `LeftSidebarView.swift:68` の `Add a project` テキストはツールチップに整理 (空状態案内は中央ペインに集約)

### Phase 4: ImportSheet (インポート画面の共通 View) [AI🤖]
- [ ] `Sources/polepole/Import/ImportSheetView.swift` を新規作成。**EmptyHubView と Settings から共有して使う共通 View**
- [ ] EmptyHubView から `.sheet(isPresented:)` で開き、Settings からは NavigationStack 内に embed
- [ ] レイアウト:
  - ヘッダ: `Found N unique projects · M already in PolePole`
  - source フィルタ chips: `[ All N | cmux x | ghq y | tmuxinator z | VSCode w ]` (排他 toggle)
  - リスト: 1行=1 candidate、チェックボックス + (pin 📌) + displayName + path + source バッジ + (古い VS Code は `last opened 90d ago`)
  - 折りたたみ `▸ Already in PolePole (M hidden)` 展開可
  - 下部: クイック選択 `[ All ] [ None ] [ cmux pinned only ]` と `[ Import N selected ]`
- [ ] Import 実行時は **必ず `ProjectsModel.importProjects(_:)` 経由**。直接 ProjectsStore を触らない
- [ ] cmux 由来の `isPinned == true` は `ImportPayload.isPinned: true`、cmux の `customTitle` があれば `displayName` に採用
- [ ] EmptyHub からの sheet を閉じたら active project が変わるので、`CenterPaneView` はプロジェクトリストの 1件目に切り替わる (既存の選択ロジックに任せる)

### Phase 5: Settings に Import タブ [AI🤖]
- [ ] 既存 Settings ウィンドウのタブ構成を把握し (おそらく `SettingsView.swift` / `polepoleApp.swift` 周辺)、新規 `Import` タブを追加
- [ ] タブを開くと「Scan for projects」ボタン (押下時に初めて scan を開始するモード) + `ImportSheetView` を embed
- [ ] EmptyHubView の自動 scan と違って、こちらは押下時 scan (明示的に開いた = 待つ前提)
- [ ] Import 完了したら toast (`ErrorBus.shared.notify` の info 系) で `Imported N projects` 表示し、Settings は閉じない

### Phase 6: 結線・微調整 [AI🤖]
- [ ] `mise run build` が通ること
- [ ] Logger で `[import]` プレフィックスのデバッグログを各 `source.discover()` / `aggregator.merge` / `ProjectsModel.importProjects` に仕込む
- [ ] `docs/DEV.md` のフラグ表に `POLEPOLE_TEST_AUTO_EMPTY_HUB` / `POLEPOLE_TEST_IMPORT_FIXTURE` を追記
- [ ] `VERIFY.md` に下記の動作確認手順番号を追記

### 動作確認 [人間👨‍💻 + AI🤖]
- [ ] [AI🤖] `POLEPOLE_TEST_AUTO_EMPTY_HUB=1` で起動 → `EmptyHubView` が表示される (`polepole-screenshot.sh`)。実データは触らない
- [ ] [AI🤖] `POLEPOLE_TEST_AUTO_EMPTY_HUB=1 POLEPOLE_TEST_IMPORT_FIXTURE=<fixture dir>` で起動 → ボタンが `Import projects...` → `Import projects (N)` に切り替わる (screenshot 2枚比較)
- [ ] [AI🤖] `[ Import projects ]` 押下 → sheet 表示 → 候補リストに cmux/ghq/tmuxinator/VSCode 由来が混在 (screenshot)
- [ ] [AI🤖] `[ cmux pinned only ]` クイック選択 → cmux pinned だけ ON (screenshot)
- [ ] [AI🤖] Import 実行 → fixture 経由で `polepole-dev/projects.json` に追加され、pin/displayName が反映 (`cat projects.json | jq`)
- [ ] [AI🤖] 重複排除: 同じ canonical key が cmux+ghq に居るときに 1 行に merge され source バッジが両方出る (fixture で検証 + unit test)
- [ ] [AI🤖] symlink 経由の path で cmux に居る workspace は **`preferredPath` のまま保存される** (canonical key は dedupe 用にしか使われない) — unit test で確認
- [ ] [AI🤖] 1件以上プロジェクトがある状態 (`POLEPOLE_TEST_AUTO_EMPTY_HUB=0`) では EmptyHub も自動 scan も走らない (`Logger` の `[import]` ログが出ない)
- [ ] [AI🤖] Settings → Import タブ → Scan ボタン押下 → sheet 同等の UI が出る (screenshot)
- [ ] [人間👨‍💻] EmptyHubView の `📖 How to use PolePole` リンクを実クリックして polepole.dev/guide が外部ブラウザで開く (PolePole 内 Claude Code からクリックは自動化できない)
- [ ] [人間👨‍💻] 「Already in PolePole (M hidden)」の展開動作と、その状態でのチェックボックス挙動の目視確認

## ログ

### 試したこと・わかったこと
- 2026-05-26: Phase 1〜6 を 1 セッションで実装完了。
  - `PRODUCT_MODULE_NAME: polepole` を base に固定して Debug / Release 両方で `@testable import polepole` を可能に (PRODUCT_NAME は `PolePole Dev` / `PolePole` で別だが module 名は共通化)
  - test target を `bundle.unit-test` で host application 付きに。XcodeGen は `schemes:` を明示しないと test target を `test` action に含めてくれなかった (CLAUDE.md の指摘どおり) → `schemes.polepole.test.targets` に明示
  - Unit test 12 ケース全部 pass (PathNormalizer / 4 source / Aggregator)
  - 実機 fixture で起動 → ログから `scan started with 5 source(s)` → `source=cursor found=0`（静かにスキップ） → `source=vscode found=2` / `cmux found=2` / `ghq found=3` / `tmuxinator found=1` → `scan done candidates=3` が確認できた
  - PolePole Dev のウィンドウ screenshot は CGWindowList 経由で「title="PolePole Dev" のウィンドウを直接 ID 指定」で撮ると Brew 版 PolePole が前面でも撮れる
- 2026-05-26: cmux session.json (`~/Library/Application Support/cmux/session-com.cmuxterm.app.json`) の構造はユーザーの実機 16 workspace で実測。`currentDirectory` / `customTitle` / `isPinned` の 3 フィールドが期待通り取れる

### 方針変更
- 2026-05-26: レビュー指摘を受けて初版から以下を変更
  - High1: `ProjectsModel.importProjects(_:)` bulk API を Phase 1 に追加。sheet 側は ProjectsStore を直接触らない設計に統一
  - High2: 内蔵 WebView 案を撤回し、外部ブラウザで `polepole.dev/guide` を開く方針に。bundle 同梱・CSS 相対パス化・PreviewWebController 流用の懸念を全て回避
  - M3: test target を Phase 1 で `project.yml` に追加。fixture 注入 init を Phase 2 で導入、`POLEPOLE_TEST_IMPORT_FIXTURE` も Phase 5 → Phase 2 に前倒し
  - M4: `ImportCandidate` に `canonicalKey` と `preferredPath` を分けて持たせる。保存は `preferredPath` で symlink 経由運用を尊重。`ProjectsModel.project(at:)` も同じ normalizer に揃える
  - M5: Phase 6 の任意 Settings 拡張は撤回し、「設計しない」に明記
  - L6: 動作確認を `POLEPOLE_TEST_AUTO_EMPTY_HUB=1` ベースに統一して実データ破壊を避ける
  - L7: tmuxinator パースの edge case (quote / comment / ERB / 環境変数 / 存在確認) を Phase 2 の仕様 + fixture に明記
  - 新規: 既存ユーザー導線として Settings に Import タブを追加 (新 Phase 5)
- 2026-05-26 (実装後): `cmux pinned only` クイック選択ボタンを撤回。cmux 使ってたユーザーにも需要が薄いとユーザー判断。`All` / `None` の 2 つだけに簡素化
