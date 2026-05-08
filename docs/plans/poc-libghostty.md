# PoC: Swift + libghostty + SwiftUI 動作検証

## 目的

[REQUIREMENTS.md](../../REQUIREMENTS.md) の想定スタック「Swift + libghostty + SwiftUI」が実現可能かを最小実装で検証する。

ここを通過しないと自作IDEの本格実装に入れない（撤退ラインを超えたら Tauri 路線にフォールバック）。

---

## スコープ

### やること
- SwiftUI プロジェクトの初期化
- libghostty の組み込み
- **1タブだけのターミナル**を表示し、入力・出力が動く状態を作る
- Ghostty 設定（`~/.config/ghostty/config`）の継承を確認
- cmux のソースを参考資料として読みつつ進める

### やらないこと（PoC 範囲外）
- 複数タブ・複数ペイン
- ファイルツリー・プレビュー・サイドバー
- AI種別バッジ・BEL通知
- キーバインド（Ctrl+M 等）
- 本実装で必要な要件全般（PoC通過後の話）

---

## 撤退判断ライン

**着手から1週間（実働ベース）で1タブのターミナルが動かなければ Tauri にフォールバック**。

具体的な撤退シグナル：
- libghostty のビルド・リンクで2日以上詰まる
- ターミナル描画は動くが入力イベントが届かない/化ける
- Ghostty config の継承方法が判明しない

逆に、上記がクリアできたら Swift 路線で本実装に進む（ファイル系UI・複数ペイン等は別途プラン化）。

---

## ステップ

### 1. cmux ソース調査（半日〜1日）
- [x] cmux のリポジトリ URL を確定する（Zenn記事 or 検索で）→ `https://github.com/manaflow-ai/cmux`
- [x] cmux を clone してビルドできる状態にする → `/Users/d0ne1s/ide/.refs/cmux/` に shallow clone 済み（実ビルドは zig 必須・PoC 範囲外）
- [x] cmux の libghostty 統合部分を読んで構造を把握:
  - libghostty をどう依存に入れているか（SPM or 手動 or バイナリ埋め込み）
  - Terminal View 相当のラッパーをどう実装しているか
  - PTY 起動・サイズ変更・入力イベントの取り回し
  - 設定ファイル読み込みのコード経路
- [x] 参照すべきファイル一覧をメモ → [poc-libghostty-step1-notes.md](./poc-libghostty-step1-notes.md)

### 2. SwiftUI プロジェクト初期化（半日）
- [x] Xcode で新規 macOS App プロジェクトを作成 → XcodeGen 経由（`project.yml` → `ide.xcodeproj`）
- [x] プロジェクト名・bundle ID 決定 → 仮名 `ide` / `local.d0ne1s.ide`
- [x] Swift Package Manager 経由 or 手動で libghostty を追加できる準備 → 手動配置方式に確定（cmux と同じ。step3 で `GhosttyKit.xcframework` をルート配置 + `project.yml` から参照）
- [x] 最小限のウィンドウが起動することを確認 → 900x532 ウィンドウ起動・スクリーンショット視認済み

### 3. libghostty 組み込み（1〜2日）
- [x] cmux と同じ方式で libghostty を依存に入れる → cmux fork prebuilt の `GhosttyKit.xcframework` をルート配置、`module GhosttyKit` を Swift から `import GhosttyKit`（Bridging Header は不要だった）
- [x] ビルド・リンクが通る状態に → `-lc++` + `Metal/QuartzCore/IOSurface/UniformTypeIdentifiers/Carbon` の system framework 追加で BUILD SUCCEEDED
- [x] libghostty の最小 API（インスタンス生成、レンダリング、入力受付）を呼び出せることを確認 → `ghostty_init` → `ghostty_config_new` → `load_default_files` → `finalize` → `ghostty_app_new` まで成功。**`~/.config/ghostty/config` を自動読込していることを diagnostic 出力で確認**（実質 step5 もクリア）。surface 作成は step4 で行う

### 4. 1タブのターミナル表示（1〜2日）
- [x] SwiftUI View（または NSViewRepresentable）として Terminal View を作成 → `GhosttyTerminalView: NSViewRepresentable` + `GhosttyTerminalNSView: NSView`
- [x] PTY を起動して `$SHELL -l` を実行 → libghostty が内蔵 PTY で zsh を fork+exec、`ttys056` 割当確認
- [x] 出力がターミナルに描画される → "Last login..." + zsh プロンプト + コマンド出力が表示される（zsh-syntax-highlighting も動作）
- [x] キー入力がシェルに渡る → `echo hello-from-ide && pwd` を AppleScript keystroke で送って実行・出力確認
- [x] ウィンドウリサイズに追従 → ウィンドウを 900x532 → 1300x762 にリサイズ後 `stty size` が `46 162` と PTY 側で正しく取得できることを確認

### 5. Ghostty 設定継承の確認（半日）
- [x] `~/.config/ghostty/config` のフォント・カラースキームが反映される → step3 の diagnostic 出力（ユーザー config の `selection-foreground: invalid value "rgb(9, 9, 7)"`）と step4 のスクリーンショット（プロンプト形式・色味）で確認済み
- [x] 反映されない場合、libghostty の API で読み込ませる方法を特定 → 問題なく反映された（`ghostty_config_load_default_files` が自動で読込）

### 6. 動作確認（VERIFY 風）
- [x] `claude` コマンドを起動して TUI が崩れずに動作する → 信頼確認画面が正しく表示・選択肢のカーソル位置も期待通り
- [x] `vim` を開いて画面遷移が正常 → REQUIREMENTS.md を vim で開き Markdown シンタックスハイライトと罫線文字も正常描画、`:q!` で復帰
- [x] `fzf` を実行してインタラクティブ動作する → ファイル一覧表示・カーソルハイライト・`7/7` ステータス・Esc 復帰すべて OK
- [x] 256色・True Color の表示確認 → 16x16 の 256 パレットと 24bit RGB グラデーションが滑らかに描画

### 7. 判断
- [x] **PoC 成功** → 本実装プラン（次のplan）の作成へ
- [ ] ~~PoC 失敗 → REQUIREMENTS.md の想定スタックを Tauri に切替、フォールバックプラン作成~~（不要）

---

## 想定リスクと対策

| リスク | 兆候 | 対策 |
|---|---|---|
| libghostty のビルドが通らない | リンクエラー、ヘッダー不足 | cmux のビルド設定を完全コピー |
| Swift 未経験で詰まる | API の使い方がわからない | Claude Code に都度聞く、cmux のコードをそのまま流用 |
| libghostty API が C ベースで Swift bridging が複雑 | 型変換でハマる | cmux のラッパーを参考、もしくは ObjC ブリッジ |
| Ghostty config の場所・読込み API が判らない | 設定が反映されない | Ghostty 本体のソースを参照、フォールバックでハードコード |

---

## ログ
（実装中の方針変更・想定外の失敗を1件10行以内で追記）

### 2026-05-08 step6+7 完了 → PoC 成功
- TUI 全種クリア: vim (Markdown ハイライト + 罫線), fzf (インクリメンタル + 7/7), claude (信頼確認画面), 256色, True Color グラデーション
- Tauri フォールバックは不要、Swift + libghostty + SwiftUI スタックで本実装に進む
- 本実装プランを別途 `docs/plans/` 配下に作成する（複数タブ・ペイン・サイドバー・ファイルツリー・プレビュー・Ctrl+M 切替・BEL通知）

### 2026-05-08 step4+5 完了
- 構成: `GhosttyManager`（app singleton + tick）、`GhosttyTerminalNSView`（CAMetalLayer + 入力）、`GhosttyTerminalView: NSViewRepresentable`、`PocLog` ヘルパに分割
- `wakeup_cb` から `DispatchQueue.main.async { ghostty_app_tick }` で wake → tick が動き、PTY 出力が描画
- Surface 作成は `viewDidMoveToWindow` で `nsview = passUnretained(self).toOpaque()` を渡すだけ
- リサイズは `setFrameSize` / `viewDidChangeBackingProperties` で `convertToBacking` → `ghostty_surface_set_size` ＋ `metalLayer.drawableSize`
- Swift 6 strict concurrency 対応: NSView 配下の C ポインタは `nonisolated(unsafe)` で deinit から触れる
- 動作確認: zsh 起動 / `echo` 実行 / リサイズ後 `stty size` 反映 / シンタックスハイライト = ユーザー config 反映
- 撤退ライン: 大幅クリア。**step6 の TUI 確認だけで PoC 結了**

### 2026-05-08 step3 完了
- xcframework 取得: cmux fork の prebuilt（`xcframework-22fa801f8`、SHA256 8d7da0bb..., 131MB圧縮 / 536MB 展開）。SHA256 検証 ok
- 配線: `import GhosttyKit` で Swift から直接呼べる。Bridging Header 不要
- リンク要件: `-lc++` + `Metal/QuartzCore/IOSurface/UniformTypeIdentifiers/Carbon`（cmux と同じ）
- 動作確認: `ghostty_init=0`, `ghostty_app_new` 非 nil, **`~/.config/ghostty/config` を読んで diagnostic を返した**（自分の config の `selection-foreground: invalid value "rgb(9, 9, 7)"` を検出）→ step5 の設定継承が事実上クリア
- 初回起動の config load は ~6s、2回目以降は 1s 未満（コールドキャッシュ）
- 構成: `Sources/ide/IdeApp.swift` の `init()` で `/tmp/ide-poc.log` に進捗を逐次書き出してデバッグ。step4 で surface を作るときも同じログ機構を使う

### 2026-05-08 step2 完了
- 構成: `project.yml` (XcodeGen) + `Sources/ide/` (SwiftUI) + `Resources/Info.plist`、bundle id `local.d0ne1s.ide`
- `mise run build` / `mise run run` / `mise run regen` で再ビルド・再起動・再生成
- `.xcodeproj` は生成物なので `.gitignore` 対象。`project.yml` が source-of-truth
- ビルド成功 (Xcode 26.4.1 / Swift 6.3.1)、ウィンドウも前面表示確認

### 2026-05-08 step1 完了
- cmux 実体は `manaflow-ai/cmux`（REQUIREMENTS.md の `japajoe/cmux` は誤りで要修正）
- ビルド方式は **GhosttyKit.xcframework を Bridging Header 経由で Swift にリンク**。prebuilt 取得経路があるので PoC で zig は必須でない
- `~/.config/ghostty/config` の継承は `ghostty_config_load_default_files()` 一発で済む見込み
- PTY は libghostty 内蔵（`io_mode = EXEC`）。自前 forkpty 不要
- 撤退ラインに対する事前見立て: ビルド・bridging・設定継承は楽勝。**入力/IME 周りが PoC で一番ボリュームが出る**（cmux で約200行）
- 詳細: [poc-libghostty-step1-notes.md](./poc-libghostty-step1-notes.md)
