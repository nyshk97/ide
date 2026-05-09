# Phase 2: プロジェクト管理 + ファイル系UI

## 目的

[REQUIREMENTS.md](../../REQUIREMENTS.md) の section 1（全体レイアウト）・section 2（プロジェクト管理）・section 3（Cmd+M 切替）・section 6（Cmd+P / Cmd+Shift+F / プレビュー）・section 7（ファイルツリー）・section 8（ログ・エラー表示）を実装し、**ターミナル単体だった ide を IDE として完成**させる。

[phase1-terminal.md](./phase1-terminal.md) でターミナルが Ghostty + cmux 相当の使い心地になっているので、ここからは「ターミナルを抱えた IDE シェル」として外側を組み上げていく。

---

## スコープ

### やること

#### レイアウト

REQUIREMENTS.md section 1 の3カラム構造に切替:

```
┌──────────┬─────────────────────┬─────────────────┐
│          │ [←][→][🌲ツリー]   │  上小ターミナル │
│ プロジェ │ ─────────────────── │ （タブ複数）    │
│ クト一覧 │ ファイルツリー      │                 │
│ サイド   │   ⇕（クリック切替） ├─────────────────┤
│ バー     │ ファイルプレビュー  │  下大ターミナル │
│          │                     │ （タブ複数）    │
└──────────┴─────────────────────┴─────────────────┘
```

- 左: プロジェクト一覧サイドバー
- 中央: ファイルツリー ⇄ ファイルプレビュー（クリックで切替、ツールバー付き）
- 右: 上下ターミナル（既に Phase 1 で完成、ここに収める）

ペイン比率はドラッグ可、保存しない（要件通り）。

#### プロジェクト管理（section 2）

- ピン留めプロジェクト + 一時プロジェクトの 2 区分
- サイドバー上部「+」ボタン → フォルダ選択 → 一時プロジェクトとして追加
- ピン留め切替（コンテキストメニュー or ボタン）
- 一時プロジェクトは MRU 順、ピン留めは手動並び替え（ドラッグ）
- 永続化: `~/Library/Application Support/ide/projects.json`、アトミック書き込み + バックアップ世代
- missing 状態（パス消失時）の表示と「再選択」「削除」メニュー
- 初回起動 UX（空状態の案内）

#### プロジェクト切替（section 3）

- Cmd+M で MRU オーバーレイ起動 + 直前にカーソル
- Ctrl 押しっぱなしで M 連打 → MRU サイクル
- Ctrl 離す → 確定（MRU 更新）
- Esc → キャンセル（MRU 更新しない）
- TUI 内でも IDE が最優先で捕捉（逃がし手段なし）

#### ファイルツリー（section 7）

- VSCode 風閲覧専用ツリー（CRUD なし）
- フォルダ先・アルファベット昇順、拡張子別アイコン
- 隠しファイル表示、`.gitignore` 対象は薄表示（トグルあり）
- fs watcher + 60秒の差分再スキャン + 手動リロードボタン
- git status バッジ（ファイル単体に M/A/D/?/!! 色付き、200ms debounce、10秒タイムアウト）
- シンボリックリンク扱い（ディレクトリ symlink は辿らず、ファイル symlink は表示）
- 右クリックメニュー: 相対パスコピー / ターミナルで開く

#### ファイルプレビュー（section 6.4）

- 閲覧専用、シングルファイル + 戻る/進む履歴ナビ
- ツリーでクリック → プレビューに差し替え（中央ペインのみ）
- Esc / 「ツリーに戻る」ボタン → ツリー復帰
- 形式別:
  - コード: NSTextView + tree-sitter or Highlightr でハイライト
  - Markdown: レンダリング済みプレビュー
  - 画像 (png/jpg/gif/svg/webp): 標準ビューワー
  - PDF: 標準 or 外部
  - その他: プレーンテキスト or 外部誘導
- サイズしきい値: 〜5MB そのまま / 5MB 超ダイアログ / 50MB 超外部誘導
- バイナリ判定（NUL 含むなら外部誘導）、UTF-8 失敗も外部誘導
- 自動リロード（行番号基準の位置維持、近傍フォールバック）
- deleted 状態表示（履歴は保持）
- Cmd+Option+O で VSCode 起動

#### Cmd+P クイック検索（section 6.1）

- ファジーマッチ + パス検索（スラッシュ含むと自動切替）
- アクティブプロジェクト内のみ
- 隠しファイル含める / `.gitignore` 対象除外（トグルあり）
- 検索対象: ファイル + ディレクトリ
- Enter で開く、Cmd+C でパスコピー、↑↓選択、Esc キャンセル
- インデックスはプロジェクト初回オープン時に構築 + watcher で増減反映

#### Cmd+Shift+F 全文検索（section 6.2）

- ripgrep を内部で使用
- 検索ポリシーは Cmd+P と同じ
- 結果上限 1000 件、10秒タイムアウト、Esc でキャンセル
- 結果一覧から該当行へジャンプ

#### ログ・診断（section 8.2、Phase 1 持ち越し）

- `~/Library/Logs/ide/` に出力するロガー
- ログレベル（error / warn / info / debug）
- ローテーション（日次・上限サイズ）
- メニュー > Help > 「最近のログを開く」
- パス等の個人情報を含むため、共有時注意の旨を UI に表示

#### エラー表示（section 8.3）

- 操作起因の単発エラー: toast
- 継続的状態異常: サイドバー or 該当ペイン内に常駐
- 詳細: ログファイル

#### 横断（section 8.1）

- 外部コマンドは shell 文字列結合せず argv 配列で起動

### やらないこと（Phase 3 以降）

- AI 起動ショートカット（Cmd+Shift+T）
- カスタム起動テンプレート
- プロンプトテンプレートのワンタッチ挿入
- プランファイル連携
- AI ヘルス監視
- クロスエージェント引き継ぎ補助
- BEL 通知の誤検知対策（誤検知が顕在化したら対応）
- セッション復元（要件には未記載、運用見て検討）

---

## 先送り判断ライン

各 step は撤退ではなく、ボリュームが膨らんだ機能を Phase 2.5 として切り出す:

- ファイルプレビューが NSTextView + tree-sitter で詰まる → Phase 2 では Highlightr に切替（簡易・速度落ちる）
- watcher が大規模リポジトリで取りこぼし多発 → 60秒スキャンの間隔を 30秒等に短縮、または手動リロード推奨に倒す
- git status の 10秒タイムアウトが頻発 → 単純な `git status --porcelain=v1 -uall` の代わりに `.git/index` watcher 主導に切替
- Cmd+P のインデックスが起動時間を悪化させる → 遅延ロードに変更（プロジェクト選択時に bg 構築）
- Cmd+Shift+F の結果 UI が複雑化 → 検索結果は単純な NSTableView で先に出す

---

## Phase 1 から引き継ぐ知見と注意点

Phase 1 で踏んだ罠を Phase 2 でも同じ轍を踏まないように記録:

- **Swift 6 strict concurrency**:
  - NSView 配下で C ポインタを `deinit` から触るには `nonisolated(unsafe)` が必須
  - NSTextInputClient 等の AppKit プロトコル準拠は `extension X: @preconcurrency Protocol` で書く
  - `Timer.scheduledTimer` の closure は nonisolated なので `Task { @MainActor in ... }` でメインに戻す

- **AppleScript の自動テスト限界**:
  - `osascript -e "click at {x, y}"` は NSViewRepresentable 配下の hit test に届かない
  - マウス起因の動作（クリック・ドラッグ・Cmd+クリック）は実機確認に倒す
  - キーストローク送信前に `set frontmost to true` を再発行すると先のクリックでの focus が戻されるので、connect 一連は単一の AppleScript ブロックで送る

- **xcodegen + mise**:
  - 新規 .swift ファイル追加後は `mise run regen`（既に build 依存に組み込み済み）
  - `project.yml` に変更を入れる場合は `dependencies:` セクションを参照（xcframework / system framework）

- **キーボードショートカットの捕捉**:
  - SwiftUI の `commands` + `keyboardShortcut` は Ghostty のキーバインディング解決に負けがち
  - Cmd+T / Cmd+W / Cmd+P / Cmd+Shift+F / Cmd+M 等の IDE 固有ショートカットは `GhosttyTerminalNSView.performKeyEquivalent` で先回りキャッチして処理する
  - Cmd+M は要件で「TUI アプリ内でも例外なく IDE が最優先で捕捉」なので最も慎重に実装

- **Ghostty fork の挙動**:
  - `child_exited.exit_code` は常に 0 で来ることがある（ghostty 側の挙動）。UI 表示には目をつぶる
  - claude code のバイナリ名は `claude.exe`（npm wrapper）。proc_pidpath で得た basename は拡張子除去で比較

- **デバッグログ**:
  - `PocLog`（`/tmp/ide-poc.log`）を引き続きデバッグ用に使ってよい
  - step10（ログ・診断）の本格実装で `~/Library/Logs/ide/` に移行する

---

## ステップ

依存関係を考慮した順序。前 step がないと後 step の動作確認が成立しない構造。

### 1. 3カラムレイアウトの枠組（半日〜1日）
- [x] `RootLayoutView`（仮）で 左サイドバー(LeftSidebarView 空) + 中央ペイン(CenterPaneView 空) + 既存 WorkspaceView を `HSplitView` で並べる
- [x] サイドバー幅は `idealWidth` 200、ターミナル領域を保護
- [x] `ContentView` を `RootLayoutView` に差し替え
- [x] **動作確認**: 起動して 3 カラム表示。ターミナルが今までどおり右ペインで動く

### 2. プロジェクトモデル（インメモリ・1日）
- [x] `Project` 型（id / path / displayName / isPinned / lastOpenedAt）
- [x] `ProjectsModel`（singleton 候補）: pinned/unpinned 配列、追加/削除/ピン留め切替
- [x] サイドバー UI: ピン留め群 + 一時群 + 「+」ボタン
- [x] 「+」で `NSOpenPanel` でフォルダ選択 → 一時プロジェクトとして追加
- [x] サイドバーから選択でアクティブ切替（`activeProject`）
- [x] **動作確認**: 「+」で 3 つフォルダ追加、アクティブ切替

### 3. プロジェクト永続化（半日〜1日）
- [x] `~/Library/Application Support/ide/projects.json` のスキーマ（`schemaVersion: 1`）
- [x] アトミック書き込み（temp file → rename）、書き込み失敗の握り潰し（コンソール警告 + UI へ表示は次 step）
- [x] バックアップ世代保持（`projects.json.1` ... `.3`）
- [x] 起動時にロード、ピン留めだけ復元（一時プロジェクトは消える、要件通り）
- [x] missing 状態の表示（パス消失・アクセス拒否）+ 右クリック「再選択」「ピン解除」
- [x] **動作確認**: ピン留めしたプロジェクトが再起動後も復元、一時は消える、ディレクトリを mv した後に missing 表示

### 4. プロジェクト切替時のターミナル状態（1日）
- [x] プロジェクトごとに `WorkspaceModel` インスタンス（PaneState を含む）を保持 → `ProjectsModel` 経由で active project の workspace を引く
- [x] プロジェクト切替で右ペインの workspace を差し替え（前のはバックグラウンドに保持）
- [x] 初回オープン時のみ shell 起動、2回目以降は表示切替だけ（要件通り）
- [x] 起動時 cwd をプロジェクトルートに設定（`ghostty_surface_config.working_directory`）
- [x] **動作確認**: 2 プロジェクトを行き来、それぞれのターミナルが独立して動作

### 5. Ctrl+M MRU 切替オーバーレイ（1日）
- [x] MRU スタック（最大5件、プロジェクトのみ、表示確定で更新、Esc で不変）
- [x] Ctrl+M でオーバーレイ起動、直前プロジェクトにカーソル
- [x] Ctrl 押しっぱなしで M 連打 → サイクル、Ctrl 離して確定
- [x] Esc でキャンセル
- [x] `NSEvent.addLocalMonitorForEvents` で **Ghostty より先に Ctrl+M を捕捉**（TUI 内でも最優先）
- [x] **動作確認**: ターミナル/vim 内のいずれでも Ctrl+M でオーバーレイが出る、サイクルは手動確認

### 6. ファイルツリー基本表示（1〜2日）
- [x] アクティブプロジェクトのファイルを再帰的に表示（フォルダ先・アルファベット順）
- [x] 展開/折り畳み状態をプロジェクトごとに保持（再起動時はリセット、要件通り）
- [x] 拡張子別アイコン（標準セット）
- [x] `.gitignore` 対象は薄表示、トグルで完全非表示
- [x] シンボリックリンク扱い（ディレクトリは辿らず、ファイルは表示、外部参照は明示）
- [x] 右クリック: 相対パスコピー / ターミナルで開く（暫定: pasteboard コピー、step8 以降で active terminal へ直接送る）
- [x] **動作確認**: 自分のリポジトリを開いて構造が見える、トグル切替は手動確認

### 7. fs watcher + git status バッジ（1日）
- [ ] ~~FSEvents API でアクティブプロジェクトを監視 → ツリー差分反映~~（Phase 2.5 へ）
- [x] ~~60秒の差分再スキャン（fallback）~~ + 手動リロードボタン（リロードボタンのみ実装）
- [x] `git status --porcelain=v1` の 200ms debounce 結果でファイル単体に M/A/D/?/!! バッジ
- [x] 10秒タイムアウト
- [x] **動作確認**: VERIFY.md を編集して保存 → 数秒後にツリーで青 M バッジ

### 8. ファイルプレビュー（1〜2日）
- [x] ツリーでファイルクリック → 中央ペインがプレビューに切替（左サイドバー・右ペインは不変）
- [x] コード: NSTextView 単純表示（Highlightr は Phase 3 へ、要件「閉じてる位で見れれば OK」）
- [x] Markdown: `AttributedString.init(markdown:)` の inlineOnly で簡易レンダリング
- [x] 画像: NSImage + ScrollView
- [x] PDF: PDFKit
- [x] バイナリ判定（NUL 検査・UTF-8 デコード）→ 外部誘導
- [x] サイズしきい値（5MB 確認 / 50MB 外部）
- [ ] ~~自動リロード（行番号基準）+ deleted 表示~~（Phase 2.5 へ、FSEvents 統合と一緒に）
- [x] Esc / 「ツリーに戻る」ボタンでツリー復帰
- [x] Cmd+Option+O で VSCode 起動
- [x] **動作確認**: .md / .swift / .plist で挙動確認、残り 3 種は VERIFY.md に手順

### 9. プレビュー履歴ナビ（半日）
- [ ] 戻る/進む履歴を中央ペインのツールバーに ← → ボタンで実装
- [ ] ファイルツリーで別ファイルを開くと履歴に追加
- [ ] 同じファイルを連続で開いても重複しない
- [ ] **動作確認**: 複数ファイルを開いて ← → でナビゲート

### 10. Cmd+P クイック検索（1〜2日）
- [ ] アクティブプロジェクト初回オープン時にファイル+ディレクトリ一覧をインデックス
- [ ] watcher で増減反映
- [ ] ファジーマッチ（実装 or `Fuse` 系ライブラリ）
- [ ] スラッシュ含むとパスマッチに自動切替
- [ ] スコアリング: 直近開いたものを上位
- [ ] UI: 中央オーバーレイ、↑↓選択、Enter で開く、Cmd+C でパスコピー、Esc キャンセル
- [ ] 「ignored を含む」トグル
- [ ] **動作確認**: 自分のリポジトリで `Read` と打って ReadView 等が上位に来る

### 11. Cmd+Shift+F 全文検索（1日）
- [ ] ripgrep を Bundle.main から呼ぶ（`Process` で argv 配列起動、`-l/--hidden`/`--no-ignore` トグルに対応）
- [ ] 結果上限 1000 件、10秒タイムアウト、Esc キャンセル
- [ ] UI: 結果一覧（ファイル + 行番号 + プレビュー）、クリックで該当行ジャンプ
- [ ] Cmd+C で行のパスコピー
- [ ] **動作確認**: 自分のリポジトリで適当な単語で grep、結果からファイルを開く

### 12. ログ・診断（半日）
- [ ] `Logger` クラス（Swift 標準 `os.Logger` ベース）
- [ ] `~/Library/Logs/ide/ide-YYYY-MM-DD.log` への永続化、日次ローテーション、上限サイズ 50MB
- [ ] error / warn / info / debug の 4 段階
- [ ] メニュー > Help > 「最近のログを開く」（Finder で reveal）
- [ ] 既存の `PocLog` 呼び出しを `Logger.debug` 等に置き換え（ハードコードされた `/tmp/ide-poc.log` を撤去）

### 13. エラー表示（半日）
- [ ] 単発エラー toast 用の overlay コンポーネント
- [ ] 継続状態異常用のサイドバー / ペイン内常駐表示（missing project, watcher 停止, PTY 異常等）
- [ ] エラーソース（toast / 常駐）の使い分けポリシーをコードコメントで明示

### 14. Phase 2 動作確認（半日）
- [ ] VERIFY.md の Phase 2 項目を全部通す
- [ ] dogfooding: 自分の普段使い 1 日（プロジェクト 5 個・タブ 3 個・claude 並列起動・ファイル検索・編集 → VSCode 起動）
- [ ] パフォーマンス（プロジェクト切替速度・ツリー描画・grep 結果反映・watcher 取りこぼし）

---

## 想定リスクと対策

| リスク | 兆候 | 対策 |
|---|---|---|
| Cmd+M を Ghostty より先に捕捉できない | TUI 内でオーバーレイが出ない | `ghostty_surface_key_is_binding` を Cmd+M に対して呼ぶ前に IDE 側で握る、cmux と同じ `performKeyEquivalent` 戦略 |
| 大規模リポジトリで初回インデックスが遅い | 起動 → 数秒固まる | 遅延ロード（プロジェクト選択時に bg 構築）、進行中は Cmd+P でグレースフル空表示 |
| watcher の取りこぼしで「無いはずのファイル」が見える | リネーム後に古い名前が残る | 60秒の差分再スキャンを最後の砦に。手動リロードもユーザーに見える位置に配置 |
| プレビューで syntax highlight が遅い | 大きい .swift ファイルでカクつく | Highlightr の chunk 描画 or 5000 行超でハイライト無効モード |
| ripgrep のバンドリング | macOS の signing で外部バイナリ実行が阻害 | Bundle.main 配下に `bin/rg` を配置、entitlements を確認 |
| プロジェクト永続化の競合 | 高速起動・終了でファイル破損 | アトミック書き込み + バックアップ世代 + 起動時の整合性チェック |

---

## ログ
（実装中の方針変更・想定外の失敗を1件10行以内で追記）

### step1: HSplitView の idealWidth 無視
- 方針変更: `idealWidth` だけだと初期は均等分割になり左サイドバーが画面の 1/3 を占めた
- 対応: `maxWidth` を サイドバー 240 / 中央 480 に絞り、右ペイン（ターミナル）だけ無限に伸びる構成に
- ペイン比率はドラッグ可・保存しないという要件は変えていない（ユーザーが広げたければ広げられる）

### step8: ファイルクリックを AppleScript で取れない問題の回避
- onTapGesture が AppleScript の click を受けない問題は step5 から続く既知の制約
- テスト用に `IDE_TEST_AUTO_PREVIEW` 環境変数を追加（active project からの相対パスでファイルを開く）
- 動作確認は env で 3 種類（Markdown / Swift / XML）まで自動、画像 / PDF / バイナリ / 大きいファイルは VERIFY.md に手動手順

### step8: NSViewRepresentable の updateNSView で string 比較
- CodePreview の updateNSView で毎回 `textView.string = text` を代入するとパフォーマンス的に良くないが、
  プレビューは別ファイルへの切替時に view ごと再生成されるので毎回の代入は実質 1 回。許容。
- AttributedString.markdown は inlineOnly モードを採用。block レベル（見出し・リスト）は plain。
  完全な markdown レンダリングは Phase 3 の Highlightr 検討と一緒に判断する。

### step7: FSEvents 統合でサイレントクラッシュ
- 想定外の失敗: FileSystemWatcher（FSEvents）と GitStatusModel（DispatchQueue + Task { @MainActor }）を統合した版で、ide が起動直後にサイレント終了する（stderr 無音、DiagnosticReports なし、exit code 6）
- 切り分けでも特定できなかったため、Phase 2.5 へ FSEvents 統合は先送り
- 代替: GitStatusModel を Timer.scheduledTimer ベースの 3 秒 polling に切り替え
  - `Timer` プロパティは `nonisolated(unsafe)` で deinit から触れるようにする
  - git status の `runGitStatus` / `parsePorcelainV1` 等の static は全部 `nonisolated`
  - statuses は `[String: Badge]`（URL の == は scheme/baseURL 違いで一致しないので `URL.standardizedFileURL.path` をキーにする）
- ファイルツリーの差分反映（新規/削除）は今回は手動 reload ボタン頼り、Phase 2.5 で FSEvents を再導入

### step7: SwiftUI の @ObservedObject の場所
- `.background(GitStatusObserver(model: gitStatus))` のような子 View に @ObservedObject を置いても、外側 body の再描画には伝播しない
- `FileTreeView` 自身に `@ObservedObject var gitStatus: GitStatusModel` を持たせて init で代入することで解決
- 子 View で監視していた objectWillChange が外側に伝わらないのは SwiftUI の View tree 評価のスコープ的な仕様

### step6: 全再帰スキャンが起動を固める
- 想定外の失敗: 初期実装は project root から再帰的に全 scan → `.git` の数千ファイルでメインスレッドが固まり、起動 2.5 秒待ってもウィンドウが取れない
- 対応: 直下子のみ初期 scan、ディレクトリ展開時に lazy scan に切り替え
- 副次効果: gitignore 判定もディレクトリ単位の小規模バッチで済むので軽い

### step6: git check-ignore の活用
- argv 配列起動（要件 8.1）+ stdin で複数 path をまとめて判定（`--stdin -z --non-matching --verbose`）
- verbose 出力は NUL 区切り 4 フィールド（source / linenum / pattern / path）
- source が空 → ignore 対象外、空でない → ignore 対象
- git バイナリは /opt/homebrew/bin/git 等の固定 PATH を試行（PATH 環境を取らない）

### step5: Ctrl+M / Cmd+M 表記の統一
- 想定外: プランは「Cmd+M」と書いていたが要件 section 3 タイトルは「Ctrl+M」、本文も Ctrl で統一
- 要件は「Enter は Return キーで打つ運用、Ctrl+M を Enter として使わない」と強い意思
- 対応: 実装は要件通り Ctrl+M、plan の表記も訂正

### step5: Ctrl+M を NSEvent.addLocalMonitorForEvents で握る
- GhosttyTerminalNSView.performKeyEquivalent より早く取れるので vim/claude 内でも捕捉できる
- chars `"m"` 比較は失敗（macOS が Ctrl+letter を CR(\r) に変換する）→ keyCode 46 で判定
- flagsChanged で Ctrl 離しを検出して commitMRUOverlay
- AppleScript の `key code 46 using {control down}` は内部的に瞬時に Ctrl down → key down/up → Ctrl up を送るので、テストでは `key down control` / `key up control` を分けて送る必要がある（押しっぱなし状態を保持してオーバーレイの screenshot を撮るため）

### step5: mruCandidates の解釈
- 当初 workspaces dict にあるもののみを候補に → 初回 Ctrl+M で 1 件しか出ず commit が no-op
- 要件「ピン留め・一時を区別せず、開いてるプロジェクトはすべて MRU の対象」を「サイドバー上の全 project」と解釈し、MRU 順優先 + 残りはサイドバー順で末尾に積む形に修正

### step4: ZStack + opacity でプロジェクト切替
- 設計判断: ZStack で全 active 化済み workspace を重ねて opacity 0/1 で切替
- ProjectsModel が `[UUID: WorkspaceModel]` を dictionary で保持し、setActive 時に遅延作成
- これで「初回オープン時のみ shell 起動、切替はインスタント、前のは生きっぱなし」を全部満たす
- 副作用: AppleScript の click が SwiftUI の onTapGesture に届かないため、テスト用に
  `IDE_TEST_AUTO_ACTIVATE_INDEX` 環境変数で起動時 active 化するデバッグ機能を追加
- working_directory は ghostty_surface_config_s.working_directory に C 文字列で渡す。
  withCString のスコープ内で ghostty_surface_new を呼ぶ必要があり、createSurface 内で分岐

### step3: AppleScript の右クリック自動化が破綻
- 想定外の失敗: Control+Click を AppleScript で送ると、過去のセッションで開いていた NSOpenPanel に干渉して input が日本語 IME ローマ字変換されてしまう
- 対応: ピン留め切替の動作確認は手動に倒し、永続化テストは projects.json を直接書いて起動 → 復元を screenshot で確認するパターンに切替
- アトミック書き込み・バックアップ世代・「再選択」メニューも手動確認に倒した（VERIFY.md 14, 15 参照）

### step3: ProjectsStore の Sendable 適合
- 静的 `shared` を `Sendable` 適合のため `struct ProjectsStore: Sendable` にしたら `FileManager.default` の stored property が non-Sendable で弾かれた
- 対応: `private var fileManager: FileManager { .default }` に変更（毎回 `.default` を返す computed property）。FileManager は内部的に thread-safe なので問題なし

### step2: NSOpenPanel の AppleScript 自動化
- 想定外の収穫: NSOpenPanel は Cmd+Shift+G でパス入力 → Enter 2 回で「追加」できることが分かった
- 「+」ボタンは座標クリックで届く（SwiftUI の Button は AXIdentifier 取得に失敗するが、座標クリックは効く）
- 行クリック・右クリックメニュー（ピン留め切替・閉じる）は座標で届く保証がないので VERIFY.md に手動手順として残した
- ドラッグ並び替えは step2 では未実装、step3 か別 step に切り出す予定
