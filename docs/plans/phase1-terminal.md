# Phase 1: ターミナルを実用レベルに完成させる

## 目的

[REQUIREMENTS.md](../../REQUIREMENTS.md) の section 4（ターミナル）・section 5 のうち AI 連携の通知バッジ部分・section 8（横断的関心事項）を実装し、**Ghostty を素で使うのと遜色ないレベルでターミナルだけ自作 IDE に置き換えられる状態**にする。

[poc-libghostty.md](./poc-libghostty.md) で 1 タブだけ動く状態にしたので、ここからは普段使いに必要な機能を埋めていく。

ファイル系 UI（プロジェクト管理・ファイルツリー・プレビュー・Cmd+P/Cmd+Shift+F）と Cmd+M プロジェクト切替は **Phase 2 以降** に切り出す。

---

## スコープ

### やること

ターミナル本体に閉じる範囲だけ。「Ghostty + cmux」レベルに追いつくのが終了条件。

#### 入力・編集系
- **クリップボード**: Cmd+C（選択あり時コピー）、Cmd+V（ペースト）、`read_clipboard_cb` / `confirm_read_clipboard_cb` / `write_clipboard_cb` の実装
- **マウス**: クリックでカーソル移動、ドラッグで範囲選択、選択後の自動コピー（mouse capture モード対応）、ホイールスクロール
- **IME（日本語入力）**: `NSTextInputClient` の `setMarkedText` / `insertText` / `firstRectForCharacterRange` 実装、`ghostty_surface_preedit` / `ghostty_surface_text` 連携
- **キー入力の本格化**: PoC の最小実装から cmux 相当に拡張（`interpretKeyEvents` 経由・`ghostty_surface_key_translation_mods` 適用・`unshifted_codepoint` 計算）
- **フォントサイズ**: Cmd++/Cmd+-/Cmd+0
- **スクロールバック消去**: Cmd+K

#### 構造系
- **複数タブ**: タブバー UI、Cmd+T 追加 / Cmd+W 閉じる / Cmd+1〜9 ジャンプ、自動タイトル（cwd or 実行中プロセス名）、閉じる確認（foreground プロセスが shell 以外なら確認ダイアログ）
- **複数ペイン**: 上小ターミナル + 下大ターミナル、各々独立したタブ群、ドラッグでリサイズ可（比率の保存はしない）
- **ペイン間フォーカス**: マウスクリックのみ（キーバインドなし）
- **shell の起動方式**: `$SHELL -l` でログインシェル起動（PoC 時点で済んでいる）、cwd は呼び出し元（最初は HOME のまま）

#### 異常系
- **PTY 異常終了表示**: shell や子プロセスが exit したらタブ内に「終了しました（exit code: N）」を表示、再起動ボタン付き、自動では閉じない
- **エラー表示**: 単発エラーは toast、継続的状態異常はサイドバーや該当ペイン内に常駐表示、詳細はログファイル

#### AI 連携
- **AI 種別バッジ**: PTY の foreground プロセス監視で Claude / Codex を検知、タブにアイコン or カラー、終了したらバッジは消える
- **BEL 通知**: ターミナル出力ストリームから `0x07` を聞き取り、非アクティブなタブ・ペインにバッジ点灯。アクティブにしたら自動クリア。粒度はタブ単位（プロジェクト単位は Phase 2 でサイドバーが入ったとき対応）

#### ターミナル出力中のリンク化
- **ファイルパス**（`path/to/file.ts:42:8` 形式）: クリックで「ファイルを開く意図」を発火（Phase 2 で実際に IDE プレビューに繋ぐ。Phase 1 では VSCode で開く動作で代替）
- **URL**（http/https のみ）: クリックで外部ブラウザ
- 検出方式: Ghostty 側の `ACTION_OPEN_URL` を利用 + 出力テキストに対する正規表現マッチ

#### 横断的
- **外部コマンド argv 配列起動**: VSCode 起動・将来のターミナルで開く等で、shell 文字列結合せず `Process` の argv 配列で起動
- **ログ・診断**: `~/Library/Logs/ide/` に行頭タイムスタンプ付きで書き出し、ローテーション（数日分・上限サイズ）。メニューから「直近のログを開く」
- **設定の永続化先**: `~/Library/Application Support/ide/` 配下に集約（Phase 2 の projects.json と同居予定）

### やらないこと（Phase 2 以降）

- 左サイドバー（プロジェクト一覧・ピン留め・MRU・追加削除）
- 中央ペイン（ファイルツリー・ファイルプレビュー・戻る/進む）
- Cmd+M プロジェクト切替（オーバーレイ + MRU サイクル）
- Cmd+P クイック検索 / Cmd+Shift+F 全文検索（ripgrep）
- VSCode で開く（Cmd+Option+O）以外の IDE 統合
- Ghostty config 以外のアプリ自前設定 UI（フォントカスタマイズ等）
- セッション復元・カスタム起動テンプレート・AI 起動ショートカット

---

## 先送り判断ライン

各ステップは PoC と違って撤退するものではないが、以下に該当した個別機能は **Phase 1.5** に切り出して先送りする：

- IME で 1 週間（実働）以上詰まったら → Phase 1 から外し、英字入力だけで先に dogfooding を始める
- リンク化が `ACTION_OPEN_URL` だけで実現できないと判明したら → Phase 1 ではプレーンテキスト表示に留め、Phase 2 で出力スキャン実装
- AI 種別バッジの foreground プロセス検知が PTY 制御端末経由で取れないと判明したら → 環境変数 `CLAUDE_CODE_*` 等の起動時シグナルで代替

機能単位で先送りすればよく、Phase 全体の白紙撤回は不要（PoC で技術的成立性が確定済みのため）。

---

## ステップ

着手順は「使える状態を早く作る」を優先。マウス・クリップボードを先、IME と複数タブはその次、装飾系（バッジ・リンク化・ログ）は最後。

### 1. PoC コードの整理と動作確認の安定化（半日）
- [x] `GhosttyTerminalView.swift` の責務を NSView / Coordinator / Manager 連携で見直す → 現状の構造（5ファイル / 328行）はシンプルで OK と判断。今後の拡張は extension（+Clipboard / +Mouse / +TextInput / +Surface）で機能ごとに分割する方針コメントを本体に残した
- [x] 動作確認スクリプトを `scripts/` 配下に整理 → `ide-launch.sh` / `ide-keystroke.sh` / `ide-screenshot.sh`
- [x] `mise run build` に `regen` を依存として組み込む → `.mise.toml` の build タスクに `depends = ["regen"]`
- [x] VERIFY.md を新規作成し、PoC の動作確認手順をベースラインとして記載 → `VERIFY.md` 作成（ビルド/起動/基本動作/リサイズ/設定継承/256色/TUI の6項目）

### 2. クリップボード（半日〜1日）
- [x] `read_clipboard_cb` / `confirm_read_clipboard_cb` / `write_clipboard_cb` を NSPasteboard 連携で実装 → `ClipboardSupport.swift` 新規作成
- [x] Cmd+C: 選択あり時のみコピー（選択がなければデフォルトキーバインド = Ctrl+C のまま通す） → `performKeyEquivalent` + `ghostty_surface_key_is_binding` で Ghostty 側のキーバインドにマッチした時のみキャッチする実装。Ghostty の copy バインディングは選択あり時のみ発火する想定（実機確認は step3 のマウス実装後）
- [x] Cmd+V: NSPasteboard から取り出して `ghostty_surface_text` で挿入 → `pbcopy` 後に Cmd+V で内容が貼り付けられることを確認済
- [x] mime type 対応（`text/plain`、画像等は無視） → `ghostty_clipboard_content_s` の mime を見て text/plain を優先採用
- [x] **動作確認**: ターミナルから別アプリへコピー、別アプリからターミナルへペースト → 別アプリ → ide のペーストは確認済。逆方向は step3 のマウス選択実装後に確認

### 3. マウス入力（1日）
- [x] `mouseDown` / `mouseDragged` / `mouseUp` で `ghostty_surface_mouse_pos` + `ghostty_surface_mouse_button` → `GhosttyTerminalNSView+Mouse.swift` に extension で実装
- [x] `scrollWheel` で `ghostty_surface_mouse_scroll`（自然スクロール方向に注意） → 実装済（実機確認は VERIFY.md 6 で）
- [x] mouse capture モード（vim 等が `\e[?1006h` で全イベント要求）に対応 → Ghostty 側が自動でハンドリングするので Swift 側は全イベント送信のみ
- [x] 選択後の自動コピー（Ghostty config の `copy-on-select` を尊重） → Ghostty 側が config を見て発火する想定
- [x] **動作確認**: ビルド・起動・80行出力までは自動で確認。マウスホイール・ドラッグ選択・vim マウスは VERIFY.md 6 に手順を残し、step5 完了時にまとめて実機確認

### 4. IME（日本語入力）（1〜2日）
- [x] `NSTextInputClient` 準拠 → `GhosttyTerminalNSView+TextInput.swift` で全プロトコル要件を実装
- [x] `interpretKeyEvents([event])` を `keyDown` で呼び出し、IME パイプラインを通す
- [x] `keyTextAccumulator` パターン（cmux 流）で IME 確定文字列を `ghostty_surface_key` に流す
- [x] `setMarkedText` → `ghostty_surface_preedit` で未確定テキストを Ghostty に伝える
- [x] `firstRectForCharacterRange` で `ghostty_surface_ime_point` を返して IME ポップアップ位置を合わせる
- [x] **動作確認**: AppleScript の `keystroke "echo"` を日本語IMEモードで送ると「えちょ」とライブ変換される（preedit 動作確認）。英数モードでの ASCII 入力も問題なし。実機での日本語確定動作は VERIFY.md 6 で手動確認

### 5. 複数タブ（1〜2日）
- [x] タブバー UI（SwiftUI、上部に表示） → `TabsView.swift` に実装、ZStack で全タブ常駐させて opacity 切替
- [x] タブモデル `TerminalTab`（surface 1個 + 表示名 + 状態）を `ObservableObject` で管理 → `TerminalTab` + `TerminalTabsModel`（singleton）
- [x] Cmd+T 追加 / Cmd+W 閉じる → `GhosttyTerminalNSView.performKeyEquivalent` で先回り処理（SwiftUI Commands は Ghostty のキーバインディング解決に先を越されるので AppKit 層で捕捉）
- [ ] Cmd+1〜9 ジャンプ → step6 以降に持ち越し
- [ ] タブ自動タイトル: `ghostty_action_set_title` のコールバックを拾って表示名更新 → step6 以降に持ち越し（現状は "shell N" 固定）
- [ ] 閉じる確認: `ghostty_surface_foreground_pid` を見て shell 以外なら NSAlert → step6 以降に持ち越し
- [x] **動作確認**: Cmd+T で 2 タブ開いてそれぞれ独立シェル、Cmd+W で閉じても残ったタブのバッファが保持される（VERIFY.md 6 の手順）

### 6. 複数ペイン（1〜2日）
- [x] 上小・下大の 2 ペイン構造 → SwiftUI `VSplitView`（自動でドラッグハンドルを出してくれる）
- [x] 各ペインが独立したタブ群を保持 → `PaneState`（旧 TerminalTabsModel をリネーム）+ `WorkspaceModel.shared` が上下を保持
- [x] ペイン間フォーカス: クリックで切替、フォーカス中のペインに Cmd+T 等が効く → `GhosttyTerminalNSView.becomeFirstResponder` で `WorkspaceModel.shared.setActive(pane)`、`performKeyEquivalent` の Cmd+T/W は `activePane` に作用
- [x] ドラッグでペイン高さ変更 → VSplitView の標準動作、PTY 側のサイズ追従は PoC で実装済（`ghostty_surface_set_size`）
- [x] **動作確認**: 上下分割と各ペイン独立 PTY（別 ttys）はスクリプトで自動確認済。実機でのクリック切替・ドラッグリサイズは VERIFY.md 6 で手動

### 7. PTY 異常終了表示と再起動（半日〜1日）
- [x] 異常終了の検知 → `action_cb` で `GHOSTTY_ACTION_SHOW_CHILD_EXITED` を捕捉（`close_surface_cb` ではなく action 経由）
- [x] exit code 取得 → `action.action.child_exited.exit_code`（ghostty fork の現状値は常に 0 で来る挙動。UI 表示自体は動作）
- [x] タブ内 overlay で「終了しました（exit code: N）」+ 再起動ボタン → `ExitedOverlayView.swift`
- [x] 再起動: 同じタブ内で新しい surface を作成 → `tab.restart()` で `generation` を increment、SwiftUI の `.id()` に混ぜて view 再生成
- [x] **動作確認**: `exit 42` で overlay 表示確認済。再起動ボタンの click は実機で確認（VERIFY.md 6）

### 8. BEL 通知 + AI 種別バッジ（1〜2日）
- [x] `ghostty_action_ring_bell` 経由で BEL を検知 → `action_cb` の `GHOSTTY_ACTION_RING_BELL` 分岐
- [x] 非アクティブなタブ・ペインにバッジ点灯、アクティブにしたら自動クリア → `TerminalTab.hasUnreadNotification` + `WorkspaceModel.isCurrentlyActive(tab:)` でゲーティング、タブ選択 / focus 取得 / setActive で自動クリア
- [ ] AI 種別バッジ: `ghostty_surface_foreground_pid` を定期的に取得 → `ps -p <pid>` で実行ファイル名取得 → `claude` / `codex` を識別 → step8-B として分離（次のステップ）
- [ ] foreground プロセス変化を監視するタイマー（500ms 程度）→ step8-B
- [x] **動作確認(BEL)**: 下ペイン shell 1 で `(sleep 2 && printf '\a') &` 仕掛け → Cmd+T で shell 2 に切替 → 2秒後に shell 1 タブ名の右に青丸が表示される

### 9. ターミナル出力リンク化（1日）
- [ ] `ghostty_action_open_url` を listen して URL クリックを処理（http/https のみ NSWorkspace で開く）
- [ ] OSC 8 hyperlink でクリック可能になっている部分を確認（標準動作で済むなら自前実装不要）
- [ ] ファイルパス検出: 出力テキストへの正規表現マッチが必要なら別途実装（Phase 2 でも可）
- [ ] **動作確認**: `echo https://example.com` の出力をクリックして Safari で開く

### 10. ログ・診断（半日）
- [ ] `~/Library/Logs/ide/` に出力するロガーを追加（既存の `PocLog` を本格化）
- [ ] ログレベル（error / warn / info / debug）、ローテーション（日次・上限サイズ）
- [ ] メニュー > Help > 「最近のログを開く」
- [ ] エラー toast と常駐表示の切り分け（NSAlert / SwiftUI overlay）

### 11. Phase 1 動作確認（半日）
- [ ] VERIFY.md に各ステップの確認手順を追記して全項目通過
- [ ] cmux で日常的にやっている操作（claude code 並列起動・vim 編集・git 操作）を 1 日通して試す
- [ ] パフォーマンス確認（タイピング遅延、大量出力時のスクロール、多タブ時のメモリ）

---

## 想定リスクと対策

| リスク | 兆候 | 対策 |
|---|---|---|
| IME の挙動が AppKit 仕様と Ghostty 仕様の境界で再現困難 | 確定文字列が二重入力される、preedit 表示が消えない | cmux の `keyTextAccumulator` + `markedTextBefore` 比較ロジックをそのまま移植 |
| ペイン分割で SwiftUI と AppKit の hit-test 競合 | クリックがペイン境界で吸われる | NSViewRepresentable のラップで `acceptsFirstMouse` を明示、cmux と同様の portal を最終手段 |
| AI 検知の foreground process がリモート shell や tmux 経由で取れない | claude バッジが点かないケースが出る | OSC 通知（claude code の hook で OSC を打たせる）にフォールバック |
| BEL の誤検知（vim の入力エラー等で連発） | バッジがすぐ点滅する | debounce + 「shell プロンプトに戻ったら自動クリア」のヒューリスティック |
| ログの個人情報漏洩 | パスや URL が含まれる | ローテーション短め + UI に共有時注意の旨表示（既に REQUIREMENTS.md 8.2 に記載） |

---

## ログ
（実装中の方針変更・想定外の失敗を1件10行以内で追記）

### 2026-05-09 step5.5 NSBeep 抑制
- 症状: Backspace / Enter 等を押すたびに macOS の「無効キー」音が鳴る（入力自体は正常）
- 原因: `interpretKeyEvents` が特殊キーを `deleteBackward(_:)` / `insertNewline(_:)` 等のセレクタコマンドに変換し、`NSResponder.doCommand(by:)` に投げる。我々は keycode 経由で処理済みだが override してないので AppKit が「未処理」と判定して NSBeep
- 対応: `GhosttyTerminalNSView` で `doCommand(by:)` を空 override（cmux と同じパターン）
- 検証: 実機でユーザー確認 OK

### 2026-05-09 step1〜step5 実機 dogfooding 結果
- マウス（ホイール/ドラッグ選択/Cmd+C）、日本語 IME（preedit/変換/確定）、複数タブ（Cmd+T/Cmd+W）すべて期待通り動作
- 唯一の発覚問題が上記 NSBeep のみ
- 撤退ライン的に Phase 1 残ステップ（複数ペイン以降）の前提が固まった
