---
build-info: docs/CHANGELOG.md は source-of-truth。public site の /changelog と /en/changelog は backend/scripts/build-changelog.mjs がここから生成する。release.sh が [Unreleased] を [X.Y.Z] - YYYY-MM-DD にリネームし、該当 section を GitHub Release notes と Sparkle appcast の <description> に注入する。
---

# Changelog

PolePole の更新履歴。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) ベース、バージョニングは [SemVer](https://semver.org/lang/ja/)。

## 書き方

このセクションは Claude Code のセッションが `mise run release` を叩く前に `[Unreleased]` を埋めるときの判断基準でもある（`git log <前回タグ>..HEAD` を読んで書き、commit してから叩く。release.sh に pause は無く、空なら止まる）。ここを読んだだけで自走できる粒度で書いてある。

### 1. フォーマット

各 list item は同じ変更を `- ja:` と `- en:` の 2 行ペアで並列に書く。build script はこの prefix で振り分けて `/changelog` (JP) と `/en/changelog` (EN) 両方を生成する。

```markdown
### ✨ Added
- ja: 機能 A を追加
- en: Added feature A
```

**制約**:

- 1 項目 = 1 行。**改行や継続行は parse 時に捨てられる** (`backend/scripts/build-changelog.mjs` は `- ja:` / `- en:` で始まる単一行のみ拾う)。長くなりすぎるなら言い回しを削るか、2 つの bullet に分割する
- インライン Markdown は `` `code` ``、`**strong**`、`[label](url)` のみサポート。画像・動画・複数段落は不可
- ja/en の bullet 数とカテゴリ配置は揃える (片方だけ書かない)
- ペアは隣接させる (`- ja:` の直後に `- en:`)

### 2. カテゴリ

```
✨ Added       — 新しい機能・ボタン・画面・ショートカット・公式サイトの新ページ
📝 Changed     — 既存機能の挙動・デフォルト値・配置・配布形式の変更
🐛 Fixed       — 「期待通りに動かなかった」のが直った
🗑️ Removed     — UI 要素・機能・ショートカットの削除
🔒 Security    — 脆弱性修正
⚠️ Deprecated  — 将来削除予定の告知
```

迷ったら **ユーザーが画面でどう感じるか** で選ぶ。「内部的にはバグ修正だが、見た目には挙動変更に見える」なら Changed で良い。

### 3. 文体

**ja は体言止め基調**にする。「〜しました」体は使わない。

```
✓ プレビュー右端に閉じるボタン (×) を追加
✓ 起動時に最後に開いていたプロジェクトを自動で開くように変更
✓ npm 経由でインストールした Claude Code / Codex CLI が通知を出さなかった問題を修正
✗ 〜を追加しました
✗ 〜変更しました
✗ 〜なりました
```

カテゴリ別の語尾テンプレ:

- Added: `〜を追加` / `〜できるように` / `〜が使えるように`
- Changed: `〜に変更` / `〜を更新` / `〜を刷新` / `〜を整理`
- Fixed: `〜問題を修正` / `〜不具合を修正`
- Removed: `〜を削除`

**en は現在形 / 単純過去をユーザー視点で**書く。

```
✓ Added a close button (×) to the right end of the preview toolbar
✓ PolePole now auto-opens the most recently used project on launch
✓ Fixed AI turn-completion notifications not firing for Claude Code installed via npm
```

ja/en は **意味の対応**であって逐語訳ではない。日本語で自然な体言止めが、英語で動詞無しになるなら自然な完文に直す。

### 4. 長さと粒度

- 1 項目は 1 文に収める。目安は **ja=60〜100 字 / en=80〜140 字**。長すぎるなら背景説明を削る
- 直前との比較を入れたいときは `(以前は〜)` / `(previously, ...)` を末尾に短く添える。それでも長くなるなら諦めて省く
- 1 リリースの bullet 数は **1〜5 が目安**。10 を超えたらカテゴリ整理が甘いか、書かなくていい項目が混ざっている

### 5. 何を書く / 何を書かない

**書く** (ユーザーがアプリ画面・公式サイト・配布物を通して気づく):

- 画面の見た目・挙動・配置の変更、新しいボタンやショートカット
- デフォルト値の変更 (ターミナルテーマ・通知音 等)
- 配布形式の変更 (zip → dmg 等。インストール体験が変わる)
- 公式サイトに増えたページ・大きく書き直したセクション
- ライセンス・課金・トライアル周りのフロー変更
- 通知・サウンド・バッジ・アップデーター挙動の修正

**書かない**:

- 内部リファクタ、テスト追加、CI / build script 調整
- ドキュメント (`docs/` `README.md` `CLAUDE.md`) だけの更新
- `MARKETING_VERSION` の bump 自体 (バージョン番号で表現される)
- 内部ログのフォーマット変更、`POLEPOLE_TEST_*` フラグの追加
- 依存ライブラリの version bump (挙動変化を伴わないもの)
- 文字列の typo 修正 (ユーザー目視レベルで気付かないもの)

### 6. AI 自動生成のチェックリスト

`mise run release` を叩く前に `[Unreleased]` を埋めるとき、AI は以下に従う:

1. **直近のリリース commit 以降の `git log` と `git diff` の両方を見る**。commit message だけでは「ユーザーにどう見えるか」が分からないので、必ず diff で確認する
2. **同じ機能の連続 commit は 1 bullet にまとめる**。「ボタンを追加 → 配置調整 → 文言調整」が 3 commit でも、結果として 1 つの新機能なら 1 bullet
3. **「これはユーザーがアプリ画面で気づくか？」を毎項目で自問**。気づかないなら書かない (上記「書かない」リスト参照)
4. **カテゴリ判定に迷ったら**: 新規追加なら Added / 既存の挙動変化なら Changed / 「壊れていたのが直った」なら Fixed
5. **文体ルール** (上記 3) に従う。書き終えたら ja は体言止めで終わっているか、en は自然な英文かを 1 度通読
6. **書く順番**: カテゴリ内では「ユーザーへのインパクトが大きい順」に並べる。決め手がなければ commit 時系列で良い
7. **ペアの整合性**: `- ja:` と `- en:` は隣接 / カテゴリ配置一致 / bullet 数一致 を最後に確認

## [Unreleased]

## [1.4.18] - 2026-08-06
### ✨ Added
- ja: Cmd+Q での終了時に確認ダイアログを追加
- en: Added a confirmation dialog when quitting with Cmd+Q

## [1.4.17] - 2026-07-16
### 🐛 Fixed
- ja: ファイルツリーの再読み込みでアプリ全体がフリーズすることがある問題を修正
- en: Fixed the whole app sometimes freezing when reloading the file tree
- ja: 長時間の使用でファイル検索・Git バッジ・差分表示が徐々に遅くなり、再起動まで回復しない問題を修正
- en: Fixed file search, Git badges, and diffs gradually slowing down over long sessions and never recovering until restart
- ja: ファイルツリーの gitignore 薄表示を、ツリー表示を止めずに後から反映するように変更
- en: The file tree now appears instantly, with gitignore dimming applied shortly after without blocking

## [1.4.16] - 2026-06-26
### 🐛 Fixed
- ja: Git 差分表示や Cmd+P のファイル検索が、外部コマンドの出力待ちで更新されなくなることがある問題を修正
- en: Fixed Git diffs and Cmd+P file search sometimes stopping updates while waiting for external command output

## [1.4.15] - 2026-06-19
### 🐛 Fixed
- ja: 子 repository がない Diff overlay の repository 見出しが `.` ではなく repository 名で表示されるように修正
- en: Fixed the Diff overlay repository heading showing `.` instead of the repository name when there are no child repositories

## [1.4.14] - 2026-06-19
### 📝 Changed
- ja: 複数 repository の差分があるとき、Cmd+D の diff overlay を repository ごとのタブ表示に変更
- en: The Cmd+D diff overlay now uses repository tabs when multiple repositories have changes

## [1.4.13] - 2026-06-17
### ✨ Added
- ja: Markdown プレビュー内の内部リンクと外部リンクを、クリック前に小さなアイコンで見分けられるように
- en: Markdown preview links now show small icons that distinguish internal navigation links from external copy-only links before you click

### 🐛 Fixed
- ja: Markdown プレビュー内のページ内リンク（例: `#makefile`）で該当見出しへ移動できなかった問題を修正
- en: Fixed Markdown preview in-page links such as `#makefile` not jumping to their target headings

## [1.4.12] - 2026-06-17
### 🐛 Fixed
- ja: Markdown プレビュー内の同じプロジェクトへのリンクをクリックしても開かないことがある問題を修正
- en: Fixed Markdown preview links to files in the same project sometimes not opening when clicked

## [1.4.11] - 2026-06-16
### ✨ Added
- ja: 親フォルダ直下の子 Git repository も Cmd+D の diff overlay と Cmd+P / Cmd+Shift+F の検索対象に含めるように追加
- en: Added direct child Git repositories to the Cmd+D diff overlay and Cmd+P / Cmd+Shift+F search results

### 📝 Changed
- ja: 子 repository に変更があるとき、上部の diff badge を件数ではなく `+` 表示に変更
- en: The top diff badge now shows `+` instead of a file count when child repositories have changes

## [1.4.10] - 2026-06-08
### 🐛 Fixed
- ja: 端末で選択したテキストを、メニューバーの Copy action 経由でもコピーできるように修正
- en: Fixed terminal selections not copying through the menu-bar Copy action

## [1.4.9] - 2026-06-06
### ✨ Added
- ja: レイアウト切替を4種類に拡張（上下2分割・左右2分割・2×2グリッド・1ペイン）— タブバーのボタンまたは `Cmd+Opt+1〜4` で切替可能
- en: Four layout modes are now available (top/bottom split, left/right split, 2×2 grid, single pane) — switch via tab bar buttons or `Cmd+Opt+1〜4`

## [1.4.8] - 2026-05-28
### 📝 Changed
- ja: Cmd+P のファイル一覧が、新規作成・削除されたファイルに自動で追従するように (FSEvents)
- en: The Cmd+P file list now updates automatically as files are created or deleted

### 🐛 Fixed
- ja: 上下シェルの境界をドラッグでつかみやすく (ヒット領域を拡張)
- en: Made the divider between the top and bottom shells easier to grab

## [1.4.7] - 2026-05-27
### ✨ Added
- ja: シェルタブを上下ペイン間でドラッグ&ドロップ または `Cmd+Shift+Opt+↑/↓` で移動できるように。shell セッション・履歴・Claude セッションを保ったまま移動可能
- en: You can now move shell tabs between the top and bottom panes via drag-and-drop or `Cmd+Shift+Opt+↑/↓` — the shell session, history, and Claude session all stay alive across the move

## [1.4.6] - 2026-05-27
### ✨ Added
- ja: 右側シェルエリアを `Cmd+/` (リバインド可) で 1 ペイン / 2 ペインに切替できるように。設定はプロジェクトごとに永続化
- en: Added `Cmd+/` (rebindable) to toggle the right shell area between 1-pane and 2-pane layouts; the choice persists per project

### 🐛 Fixed
- ja: 設定でショートカットを録音中、既存の固定ショートカット (⌘P / ⌘T / ⌘W 等) を割り当てようとしたとき衝突警告が出ず裏で実動作してしまう問題を修正
- en: Fixed an issue where rebinding a shortcut to an existing built-in (⌘P / ⌘T / ⌘W, etc.) silently triggered the built-in action instead of showing a conflict warning

## [1.4.5] - 2026-05-26
### ✨ Added
- ja: ファイルツリーのツールバーにファイル名検索 (⌘P) / 全文検索 (⌘⇧F) を開くボタンを追加
- en: Added search buttons to the file tree toolbar — click to open quick file search (⌘P) or full-text search (⌘⇧F)

### 📝 Changed
- ja: 検索オーバーレイ表示中、枠外をクリックするとオーバーレイを閉じるように
- en: Clicking outside the search overlay now closes it

### 🐛 Fixed
- ja: ⌘P でクイック検索を開いたあと ⌘⇧F で全文検索に切り替えた際、Esc を 2 回押さないと閉じなかった問題を修正
- en: Fixed an issue where Esc had to be pressed twice to close the full-text search after switching from quick search (⌘P → ⌘⇧F)

## [1.4.4] - 2026-05-26
### 📝 Changed
- ja: 起動時に、最後に開いていたプロジェクトを自動で開くように変更 (これまでは未選択状態で起動していました)
- en: PolePole now auto-opens the most recently used project on launch (previously it started with no project selected)

## [1.4.3] - 2026-05-26
### ✨ Added
- ja: ファイルプレビューのツールバー右端に閉じるボタン (×) を追加 (以前は Esc / Cmd+W、または divider を端までドラッグするしかなかった)
- en: Added a close button (×) to the right end of the file preview toolbar (previously, the only ways to close were Esc / Cmd+W or dragging the divider to the edge)

## [1.4.2] - 2026-05-26
### 📝 Changed
- ja: ファイル詳細画面で、ファイル名にホバーするとコピーアイコンが現れ、クリックすると相対パスがコピーされて 1 秒間チェックマークに変わるように変更 (以前は下線が引かれるだけで、結果のトーストも画面右下に出ていた)
- en: In the file preview, hovering the filename now reveals a copy icon and clicking copies the relative path with a 1-second checkmark feedback right next to the button (previously it only underlined and showed a toast in the far corner)

## [1.4.1] - 2026-05-26
### ✨ Added
- ja: シェルタブの並び替えをドラッグ&ドロップで行えるように
- en: You can now reorder shell tabs by drag and drop
- ja: ⌘⌥←/→ でアクティブペイン内のタブを切り替え、⌘⌥↑/↓ で上下ペインのフォーカスを切り替え
- en: ⌘⌥←/→ now switches tabs within the active pane, and ⌘⌥↑/↓ moves focus between the top and bottom panes

## [1.4.0] - 2026-05-26
### ✨ Added
- ja: プロジェクトが 0 件のときの中央ペインを「Get started」ハブに刷新。フォルダ選択ボタンに加え、cmux / tmuxinator / VS Code・Cursor / ghq 配下から既存プロジェクトを発見してまとめて取り込めるインポート画面を追加 (cmux のピン留めと表示名は引き継ぎ)
- en: Reworked the empty center pane into a "Get started" hub. In addition to picking a folder, you can bulk-import projects detected from cmux / tmuxinator / VS Code / Cursor / ghq (cmux pin state and titles carry over)
- ja: 設定 → Import タブから、既にプロジェクトが登録されているユーザーも同じインポート機能を呼び出せるように
- en: Added an "Import" tab to Settings so users with existing projects can run the same importer

## [1.3.2] - 2026-05-26
### 🐛 Fixed
- ja: npm 経由でインストールした Claude Code / Codex CLI が AI ターン完了通知 (音・赤いバッジ) を出さなかった問題を修正
- en: Fixed AI turn-completion notifications (sound / red badge) not firing for Claude Code / Codex CLI installed via npm

## [1.3.1] - 2026-05-25
### 📝 Changed
- ja: ターミナルのデフォルトテーマを GitHub Dark から Apple System Colors に変更 (デフォルト状態でも本文の文字が明るく見えるように)
- en: Changed the default terminal theme from GitHub Dark to Apple System Colors so the default body text is brighter
- ja: シェルタブを閉じるときの確認ダイアログを既定でオフに変更
- en: Disabled the close-confirmation dialog for shell tabs by default

## [1.3.0] - 2026-05-25
### 📝 Changed
- ja: プレビューの ← / → 履歴を時系列ログ方式に変更 (← で戻った状態から別ファイルを開いても forward 履歴が消えない)
- en: Preview ← / → history is now chronological — opening a new file after going back no longer truncates the forward entries
- ja: プレビューツールバーの ← / → ボタンをファイル名の左側に移動 (ファイル名の長さでボタン位置がブレない)
- en: Moved the ← / → buttons in the preview toolbar to the left of the file name so their position no longer shifts with file-name length

### 🐛 Fixed
- ja: プレビューで ← / → / markdown 内リンク / Cmd+P / Cmd+Shift+F で別ファイルに移ったとき、ファイルツリー側のハイライトが追従するように修正
- en: File tree highlight now follows the current preview file when navigating via ← / →, markdown links, Cmd+P, or Cmd+Shift+F

### 🗑️ Removed
- ja: ツリー ↔ プレビューのトグルボタン (ツリー上部の doc.text アイコン) と Cmd+J ショートカットを削除 (4 カラムレイアウトでツリーとプレビューが同時に見えるため不要)
- en: Removed the tree ↔ preview toggle button (doc.text icon above the tree) and the Cmd+J shortcut — both are no longer needed now that the tree and preview are visible at the same time in the 4-column layout
- ja: プレビューツールバー先頭の「閉じる」アイコン (📁) を削除 (閉じるには Esc / Cmd+W、または divider を端までドラッグ)
- en: Removed the "close" icon (📁) at the start of the preview toolbar — close via Esc / Cmd+W or by dragging the divider to the edge instead

## [1.2.0] - 2026-05-25
### ✨ Added
- ja: 左の **プロジェクト一覧サイドバー** を折りたためる機能を追加 (デフォルト Cmd+S でトグル、折りたたみ中は左端の細いハンドルをクリックでも展開可能。Cmd+, の設定画面でショートカット変更可)
- en: Added a way to collapse the **project sidebar** to reclaim screen width (toggle with Cmd+S by default; when collapsed, click the thin handle on the left edge to expand. The shortcut is rebindable in Settings, Cmd+,)

### 📝 Changed
- ja: ファイルツリーとプレビューを別ペインに分離し、ファイルを開いてもツリーが消えないように変更 (ファイル未オープン時は 3 列、プレビューを開いたときだけプレビュー列が現れる 4 列レイアウト)
- en: File tree and preview are now in separate panes — opening a file no longer hides the tree (the layout becomes 4 columns only while a preview is open; otherwise it stays 3 columns as before)
- ja: プレビューの表示状態をプロジェクトごとに独立して保持するように変更 (プロジェクト A でプレビューを開いて B に切り替えても B のプレビュー状態がそのまま)
- en: Preview open/closed state is now tracked per project (switching from A to B keeps B's own preview state instead of inheriting A's)
- ja: プレビューを Esc / Cmd+W で閉じる挙動を、プレビューにフォーカスがあるときだけに限定 (端末側にフォーカスがあるときの Cmd+W は今まで通り端末タブの close)
- en: Esc / Cmd+W now only closes the preview when the preview itself has focus — when the terminal has focus, Cmd+W still closes the terminal tab as before

## [1.1.5] - 2026-05-25
### 📝 Changed
- ja: アプリの配布形式を .zip から .dmg に変更 (ダブルクリックすると Finder にマウントされ、Applications フォルダにドラッグしてインストールする macOS 標準フローに)
- en: The app is now distributed as .dmg instead of .zip — double-click to mount and drag PolePole.app to your Applications folder, the standard macOS install flow

## [1.1.4] - 2026-05-25
### 📝 Changed
- ja: アプリと公式サイトをダークモード固定に変更 (OS のライトモード設定には追従しない)
- en: The app and the official site now always render in dark mode and no longer follow the system light mode setting

## [1.1.3] - 2026-05-25
### 🐛 Fixed
- ja: プレビューに表示中の Markdown / コードで、文字列を選択して Cmd+C を押してもコピーされない問題を修正 (端末側の Cmd+C バインドが先取りしていたのを、フォーカス中のペインだけが握るように変更)
- en: Fixed an issue where Cmd+C did not copy selected text in the Markdown / code preview (the terminal's Cmd+C binding was intercepting the shortcut; now only the focused pane consumes it)
- ja: 閲覧中の Markdown / コードファイルがディスク上で更新されたとき、プレビューが先頭にスクロールバックしないように修正 (同じファイルの再描画はスクロール位置を保持、別ファイルに切り替えたときだけ先頭に戻る)
- en: When the Markdown or code file you are previewing is updated on disk, the preview no longer jumps back to the top — the scroll position is preserved on same-file refreshes (it still resets when you open a different file)

## [1.1.2] - 2026-05-24
### ✨ Added
- ja: 公式サイトに [/guide](https://polepole.dev/guide) ページを追加 (初回起動・ライセンス適用・アップデート・Ghostty 設定の早見表)
- en: Added a new [/guide](https://polepole.dev/guide) page on the official site, covering first launch, license activation, updates, and Ghostty configuration

### 📝 Changed
- ja: Cmd+P (ファイル名検索) と Cmd+Shift+F (全文検索) で、`.gitignore` を持たないプロジェクトでも `node_modules` / `target` / `__pycache__` / `dist` / `vendor` / `.next` などの典型的なディレクトリを常に検索対象から除外するように変更
- en: Cmd+P (file search) and Cmd+Shift+F (full-text search) now always exclude common build/vendor/cache directories (`node_modules`, `target`, `__pycache__`, `dist`, `vendor`, `.next`, etc.) even when the project has no `.gitignore`
- ja: ファイルツリーの reload ボタン・preview ↔ tree 切替ボタン・`.gitignored` 表示トグルに Git ボタンと同じホバー背景を追加し、操作可能な要素であることを分かりやすく変更
- en: The reload button, preview ↔ tree toggle, and the hide-ignored toggle in the file tree now share the same hover background as the Git button, making them feel more clearly clickable
- ja: ファイルツリーを reload した後も、開いていたディレクトリの展開状態を保持するように変更
- en: The file tree now keeps each directory's expand state across reloads

### 🗑️ Removed
- ja: Cmd+P 検索オーバーレイの「ignored を含む」トグルボタンを削除 (常に除外する挙動に統一)
- en: Removed the "include ignored" toggle button from the Cmd+P overlay (it now always excludes ignored entries)

## [1.1.1] - 2026-05-24
### 📝 Changed
- ja: トライアル期限切れ画面 (ペイウォール) を整理 — アプリアイコンを表示し、価格表記を公式サイトと同じ ¥9,900 に統一、レイアウトの余白を調整
- en: Polished the trial-expiry paywall: shows the app icon, matches the website's ¥9,900 price, and tightened the layout spacing
- ja: 購入後のライセンス受け取りページを刷新 — アプリアイコン・ライセンスキーのコピーボタン・3 ステップのアクティベートガイドを追加
- en: Redesigned the post-purchase license page with the app icon, copy-to-clipboard buttons, and a 3-step activation guide

### 🗑️ Removed
- ja: ペイウォールの「ライセンスキーを再送」ボタンを削除 (紛失時はお問い合わせフォームから連絡)
- en: Removed the "Resend license key" button from the paywall (please use the contact form if you lose your key)

## [1.1.0] - 2026-05-24
### ✨ Added
- ja: ライセンス購入フローを追加。14 日無料トライアル → Stripe で決済 → メールで届くライセンスキーでアクティベーション
- en: Added license purchase flow: 14-day free trial → Stripe checkout → activate with the license key delivered by email
- ja: トライアル期限切れ後の起動ロック画面を追加。期限切れ後はライセンスを入れるまで起動できない
- en: Added an expiry lock screen after the trial period; the app stays locked until a license key is entered
- ja: 公式サイト [polepole.dev](https://polepole.dev) を公開 (LP + プライバシーポリシー + 利用規約 + 特定商取引法)
- en: Launched the official site at [polepole.dev](https://polepole.dev) with landing page, privacy policy, terms, and Japanese commercial-disclosure page
- ja: 問い合わせフォームを公式サイトに追加 (HyperForm 連携)
- en: Added a contact form on the official site (backed by HyperForm)
- ja: 公式サイトを英語対応 (現時点では `/en/` 配下はスタブ + 言語スイッチ。本翻訳は近日)
- en: Added i18n scaffolding for the official site; `/en/` pages are currently stubs with a language switcher, full translations coming soon

### 📝 Changed
- ja: LP の hero CTA を「無料で試す」+「価格を見る」に整理。購入ボタンも「ライセンスを購入する」に統一
- en: Reorganized the LP hero CTAs to "Try for free" + "See pricing", and unified the purchase buttons to "Buy a license"

## [1.0.0] - 2026-05-23

### 📝 Changed
- ja: `ide` から **PolePole** にリブランド (これ以前は `ide` という名前で内部開発)。Bundle ID は `local.d0ne1s.polepole` (Debug ビルドは `.dev` suffix)
- en: Rebranded from `ide` to **PolePole** (previously developed internally as `ide`). Bundle ID is now `local.d0ne1s.polepole` (Debug builds use a `.dev` suffix)
- ja: アプリアイコンを刷新 (青グラデ背景に象のアイコン)
- en: Refreshed the app icon (elephant icon on a blue gradient background)

---

旧 `ide` 時代 (v0.0.1〜v1.0.14, 2026-05-01〜2026-05-23) の履歴は GitHub Releases の [nyshk97/ide releases](https://github.com/nyshk97/ide/releases) を参照。Sparkle 配信の凍結履歴として残しています。
