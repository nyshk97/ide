# 動作確認

実装・修正後に動作を確認するための手順集。変更内容に応じて関係する項目だけ実行する（毎回全部やらない）。

## 前提

- 開発ビルドは `mise run build`（XcodeGen による `regen` を内包）
- `.app` の出力先は `/tmp/ide-build/Build/Products/Debug/ide.app`
- 動作確認用ヘルパは `scripts/` 配下:
  - `scripts/ide-launch.sh [wait_seconds]` — kill + open + 起動待ち
  - `scripts/ide-keystroke.sh [--enter|--keycode N] "text"` — `osascript` でキーストローク送信
  - `scripts/ide-screenshot.sh <output_path>` — フロントウィンドウ領域をキャプチャ

ログは `/tmp/ide-poc.log`（init() で reset）に書き出される。`tail -f /tmp/ide-poc.log` で追える。

## ⚠️ projects.json を触る検証は事前バックアップ必須

以下のセクションは `~/Library/Application Support/ide/projects.json` をテスト用フィクスチャで上書きし、最後に `rm -f` で消します。**ユーザーがピン留めしているデータが入っているので、検証前に必ずバックアップを取り、検証後に復元してください。**

```bash
# 検証開始前
BACKUP_DIR=$(mktemp -d)
cp -a "$HOME/Library/Application Support/ide/" "$BACKUP_DIR/ide-backup" 2>/dev/null || true

# 検証完了後
rm -rf "$HOME/Library/Application Support/ide"
mv "$BACKUP_DIR/ide-backup" "$HOME/Library/Application Support/ide" 2>/dev/null || true
```

対象セクション: 13, 14, 16, 17, 19, 23, 25, 28, 30 など `cat > .../projects.json` を含む全節。

---

## 1. ビルドと起動

```bash
mise run build
./scripts/ide-launch.sh
```

期待: `** BUILD SUCCEEDED **` と表示され、ide ウィンドウが前面に開く。

ログ確認:
```bash
cat /tmp/ide-poc.log
```
期待出力に `[ghostty] init=0`、`[ghostty] app_new ok`、`[surface] new ok` が含まれる。

## 2. ターミナル基本動作

```bash
./scripts/ide-launch.sh
./scripts/ide-keystroke.sh --enter "echo hello && pwd"
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-basic.png
```

スクショに `hello` の出力と HOME 相当のパスが表示されていること。

## 3. リサイズ追従

```bash
./scripts/ide-launch.sh
osascript -e 'tell application "System Events" to tell process "ide" to set size of front window to {1300, 800}'
sleep 0.3
./scripts/ide-keystroke.sh --enter "stty size"
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-resize.png
```

`stty size` の出力（行 列）がウィンドウサイズに見合った値に変わっていること（PTY rows/cols が同期している）。

## 4. Ghostty 設定継承

```bash
./scripts/ide-launch.sh
grep "diag\[" /tmp/ide-poc.log
```

`~/.config/ghostty/config` に設定ミスがあれば diagnostic が出る。または UI 上で自分の Ghostty 設定どおりのフォント・カラースキームになっていること。

## 5. 256色・True Color

```bash
./scripts/ide-launch.sh
./scripts/ide-keystroke.sh --enter "for i in {0..15}; do for j in {0..15}; do printf \"\\x1b[48;5;\$((i*16+j))m  \\x1b[0m\"; done; printf \"\\n\"; done"
sleep 0.5
./scripts/ide-keystroke.sh --enter "for i in {0..127}; do printf \"\\x1b[48;2;\$((i*2));\$((255-i*2));128m \\x1b[0m\"; done; printf \"\\n\""
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-color.png
```

スクショに 16x16 の 256 パレットと、24bit RGB のなめらかなグラデーションが映っていること。

## 6. URL リンク化

```bash
./scripts/ide-launch.sh
./scripts/ide-keystroke.sh --enter "echo https://example.com"
```

実機で:
- 出力中の URL をマウスホバー → 下線が出る（Ghostty 標準動作）
- `Cmd+クリック` で Safari が開く
- `file://` 等は ide 側で弾く（無視）

## 7. AI 種別バッジ

```bash
./scripts/ide-launch.sh
osascript -e 'tell application "System Events" to tell process "ide" to set frontmost to true'
sleep 0.3
osascript -e 'tell application "System Events" to key code 102'
./scripts/ide-keystroke.sh --enter "claude"
sleep 4
./scripts/ide-screenshot.sh /tmp/v-ai-badge.png
```

期待: タブ名「shell 1」の左に 🅒 アイコン（オレンジ tint）が出る。Esc で claude を抜けるとアイコンが消える。

`codex` 起動時は 🅞（緑 tint）が出る。識別は `proc_pidpath` の basename から拡張子を除いて行う（claude のバイナリは `claude.exe` で来るので注意）。

## 7. BEL 通知

```bash
cat > /tmp/bel-test.sh <<'SCRIPT'
(sleep 2 && printf '\a') &
SCRIPT
chmod +x /tmp/bel-test.sh

./scripts/ide-launch.sh
osascript -e 'tell application "System Events" to tell process "ide" to set frontmost to true'
sleep 0.3
osascript -e 'tell application "System Events" to key code 102'
osascript -e 'tell application "System Events" to keystroke "source /tmp/bel-test.sh"'
osascript -e 'tell application "System Events" to key code 36'
sleep 0.4
# Cmd+T で別タブに切替（shell 1 が非active になる）
osascript -e 'tell application "System Events" to keystroke "t" using command down'
sleep 3
./scripts/ide-screenshot.sh /tmp/v-bel.png
```

期待: スクショで `shell 1` のタブ名の右に青丸（●）バッジが表示されている（非active タブで BEL 受信）。

実機での確認:
- `shell 1` タブをクリックで切替 → バッジが消える
- アクティブタブ自身で `printf '\a'` を実行 → バッジは出ない（自分で触っているので未読扱いしない）

## 7. PTY 異常終了表示と再起動

```bash
./scripts/ide-launch.sh
```

ide のターミナルで:
```
exit 42
```

期待:
- タブ内に「シェルが終了しました」「exit code: N」+「再起動」ボタンの overlay が表示される
- タブは自動で閉じない
- 「再起動」ボタンをクリック → 新しいシェルが起動して overlay が消える、`Last login: ...` が新しい時刻で表示

注: ghostty fork の現状の挙動で exit_code は常に 0 になることがある（取得経路は正しいが、ghostty 側で `WEXITSTATUS` 等の処理が違う可能性）。表示自体・再起動動作は機能する。

## 7. 複数ペイン（手動確認）

```bash
./scripts/ide-launch.sh
```

実機で:
- 上下に2つのターミナルが分割表示されている（VSplitView）
- 起動直後は **下ペインがアクティブ**（カーソルが塗りつぶし、上は中空）
- 上下ペインの境界をドラッグして高さを変えられる
- 上ペインをクリック → 上ペインがアクティブになる（カーソル塗り → 下が中空に）
- 上ペインで `Cmd+T` → 上ペインのタブだけ追加される（下ペインは影響しない）
- 同じく下ペインで `Cmd+T` → 下ペインのタブが追加される

各ペインは独立した PTY なので別の `ttys*` が割り当てられる:
```bash
./scripts/ide-keystroke.sh --enter "tty"
```
を上下それぞれで打って異なる TTY が出ることを確認（手動でアクティブ切替後、各ペインで実行）。

## 7. 複数タブ

```bash
./scripts/ide-launch.sh
osascript -e 'tell application "System Events"
  tell process "ide"
    set frontmost to true
  end tell
  delay 0.3
  key code 102
  delay 0.2
  keystroke "echo tab-1"
  delay 0.1
  key code 36
  delay 0.5
  keystroke "t" using command down  -- 新規タブ
  delay 0.7
  keystroke "echo tab-2"
  delay 0.1
  key code 36
end tell'
sleep 1
./scripts/ide-screenshot.sh /tmp/v-tabs.png
```

期待: タブバーに `shell 1` と `shell 2` が並び、shell 2 がアクティブで `tab-2` 出力が見える。

```bash
osascript -e 'tell application "System Events"
  tell process "ide"
    set frontmost to true
  end tell
  delay 0.3
  keystroke "w" using command down  -- アクティブタブ閉じる
end tell'
sleep 1
./scripts/ide-screenshot.sh /tmp/v-tabs-close.png
```

期待: shell 2 が閉じて shell 1 だけ残り、shell 1 のバッファ（`tab-1` 出力）が保持されている。

## 7. IME（日本語入力）

入力ソースが日本語のとき、AppleScript で英字を打つとライブ変換が走る:
```bash
./scripts/ide-launch.sh
osascript -e 'tell application "System Events" to keystroke "echo"'  # IME が日本語ローマ字なら「えちょ」になる
```
→ ターミナル上で preedit が表示される（赤文字 = zsh-syntax-highlighting でコマンド未存在判定）= `setMarkedText` → `ghostty_surface_preedit` 経路が動作。

英数モードに戻して ASCII 入力が壊れていないか:
```bash
./scripts/ide-launch.sh
osascript -e 'tell application "System Events" to key code 102'  # 英数キー
./scripts/ide-keystroke.sh --enter "echo ascii-after-eisuu"
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-ime-ascii.png
```

実機での日本語確認（手動）:
- 入力ソースを日本語に切替 → ide にフォーカス
- 「あ」と打って preedit が出る、Space で変換、Enter で確定 → ターミナルに「あ」が入る

## 7. マウス（手動確認）

```bash
./scripts/ide-launch.sh
./scripts/ide-keystroke.sh --enter "for i in {1..80}; do echo \"line \$i\"; done"
```

以下を実機で確認:
- マウスホイールで上下スクロールができる
- ドラッグでテキスト選択、選択範囲がハイライトされる
- 選択後 `Cmd+C` でクリップボードへコピーされる（`pbpaste` で確認）
- `vim` 起動後、マウスホイールでバッファスクロールできる

## 7. クリップボードペースト

```bash
echo "expected-payload-$(date +%s)" | tr -d '\n' | pbcopy
./scripts/ide-launch.sh
./scripts/ide-keystroke.sh "echo "
osascript -e 'tell application "System Events" to keystroke "v" using command down'
sleep 0.3
./scripts/ide-keystroke.sh --keycode 36
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-paste.png
```

スクショの出力に `pbcopy` で渡した文字列が映っていること。ログ確認:
```bash
grep "\[clip\]" /tmp/ide-poc.log
```

## 8. TUI 動作確認

### vim

```bash
./scripts/ide-launch.sh
./scripts/ide-keystroke.sh --enter "vim REQUIREMENTS.md"
sleep 1.5
./scripts/ide-screenshot.sh /tmp/v-vim.png
./scripts/ide-keystroke.sh ":q!"
./scripts/ide-keystroke.sh --keycode 36  # Enter
```

スクショで Markdown のシンタックスハイライト・罫線文字・ステータスラインが正しく描画されていること。

### fzf

```bash
./scripts/ide-keystroke.sh --enter "ls | fzf --height=50%"
sleep 1
./scripts/ide-screenshot.sh /tmp/v-fzf.png
./scripts/ide-keystroke.sh --keycode 53  # Esc
```

ファイル一覧が表示され、カーソル行がハイライトされ、`N/N` のステータスが見えること。

### claude

```bash
./scripts/ide-keystroke.sh --enter "claude"
sleep 4
./scripts/ide-screenshot.sh /tmp/v-claude.png
./scripts/ide-keystroke.sh --keycode 53  # Esc
```

claude code の起動画面（信頼確認やプロンプト入力欄）が崩れずに描画されること。

---

## Phase 2

### 9. 3カラムレイアウト

```bash
./scripts/ide-launch.sh
./scripts/ide-screenshot.sh /tmp/v-3col.png
./scripts/ide-keystroke.sh --enter "echo phase2-step1-ok && pwd"
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-3col-terminal.png
```

期待:
- スクショに 3 カラム（左 `Projects` / 中央 `Tree / Preview` / 右 ターミナル）が表示される
- 起動時の幅は サイドバー 約240px、中央 約480px、残りがターミナル
- 右ペインは上下 2 タブ（VSplitView）が引き続き動作
- `echo phase2-step1-ok` の出力が右ペインのアクティブターミナルに表示される

実機での手動確認:
- 左サイドバーと中央ペインの境界をドラッグで動かせる
- 中央ペインと右ペインの境界をドラッグで動かせる
- ウィンドウ最小幅は 1000px（それ以下に縮められない）

### 10. プロジェクト追加（インメモリ・自動）

```bash
./scripts/ide-launch.sh
./scripts/ide-screenshot.sh /tmp/v-step2-empty.png
```

期待: 起動直後はサイドバー上部に「+」ボタンのみ、中央ペインに `フォルダを追加して始めよう` が表示。

NSOpenPanel 経由で 3 つフォルダを追加（座標クリック + Cmd+Shift+G でパス入力）:

```bash
add_project() {
  /usr/bin/osascript <<OSA
tell application "System Events"
  tell process "ide"
    set frontmost to true
    delay 0.3
    set winPos to position of front window
    set wx to (item 1 of winPos) as integer
    set wy to (item 2 of winPos) as integer
    click at {wx + 92, wy + 44}
    delay 0.6
    keystroke "g" using {command down, shift down}
    delay 0.4
    keystroke "$1"
    delay 0.2
    key code 36
    delay 0.4
    key code 36
    delay 0.4
  end tell
end tell
OSA
}
add_project "/Users/d0ne1s/ide"
add_project "/Users/d0ne1s/Downloads"
add_project "/tmp"
sleep 0.4
./scripts/ide-screenshot.sh /tmp/v-step2-3rows.png
```

期待:
- サイドバーに 3 行（最後に追加したものが最上、MRU 順）
- 一番上の行（最後に追加）にアクティブハイライト（青背景）
- 各行に `folder` アイコン（ピン留め前は灰色）
- 中央ペインに最後に追加したプロジェクトの displayName + フルパス + `Tree / Preview（step6 以降で実装）` が表示

注意: `Cmd+Shift+G` のパス入力は NSOpenPanel の状態によっては親ディレクトリが選択されることがある（既知の挙動、機能には影響なし）。

### 11. プロジェクト切替・ピン留め・閉じる（手動）

座標クリックで AppleScript 経由でも届くが、Phase 1 の知見どおりマウス起因は実機確認に倒す。

実機で確認:
- 別の行をクリック → アクティブハイライトが移動、中央ペインのパスが切り替わる
- 行を右クリック → 「ピン留め」「閉じる」のメニューが出る
- 「ピン留め」 → 行が上部に移動、アイコンがオレンジの 📌 に変わる、ピン留めセクションと一時セクションの間に薄い divider が出る
- ピン留め済みの行で右クリック → 「ピン解除」が出る、選ぶと一時セクションに戻る
- 「閉じる」 → 行が消える、アクティブだった場合は隣の行がアクティブになる
- 全部閉じる → 中央ペインが「フォルダを追加して始めよう」に戻る

### 12. プロジェクト永続化（自動）

`~/Library/Application Support/ide/projects.json` には pinned / temporary 両方が保存され、再起動でサイドバーに復元される（明示的に「閉じる」した時のみ消える）。

```bash
pkill -x ide 2>/dev/null
mkdir -p "$HOME/Library/Application Support/ide"
mkdir -p /tmp/ide-step3-test/willmove /tmp/ide-step3-test/temp-proj
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"willmove","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/tmp/ide-step3-test/willmove"},
    {"displayName":"temp-proj","id":"33333333-3333-3333-3333-333333333333","isPinned":false,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"/tmp/ide-step3-test/temp-proj"}
  ],
  "schemaVersion" : 1
}
JSON
./scripts/ide-launch.sh
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-step3-restored.png
```

期待: ピン留めセクションに ide / willmove が並ぶ（ボールド表示）、その下に区切り線 → 一時セクションに temp-proj が出る（レギュラー表示）、中央ペインに「左からプロジェクトを選択」。

temporary が永続化されている確認（自動）:
```bash
pkill -x ide 2>/dev/null
sleep 0.5
# allOrdered の index 2（pinned 2件 + temporary 1件目 = temp-proj）をアクティブ化
IDE_TEST_AUTO_ACTIVATE_INDEX=2 /tmp/ide-build/Build/Products/Debug/ide.app/Contents/MacOS/ide >/tmp/ide-stdout.log 2>&1 &
sleep 3
# temp-proj の lastOpenedAt が更新されていれば temporary も永続化されている
python3 -c "import json; d=json.load(open('$HOME/Library/Application Support/ide/projects.json')); [print(f\"{p['displayName']}: {p['lastOpenedAt']}\") for p in d['projects']]"
pkill -x ide 2>/dev/null
```

期待: temp-proj の lastOpenedAt が `2026-05-09T03:00:00Z` から起動時刻に更新されている。

### 13. missing 状態（自動）

```bash
pkill -x ide 2>/dev/null
mv /tmp/ide-step3-test/willmove /tmp/ide-step3-test/moved-away
./scripts/ide-launch.sh
sleep 0.5
./scripts/ide-screenshot.sh /tmp/v-step3-missing.png
```

期待: willmove が黄色 ⚠ アイコン + 半透明で表示、ide は通常表示のまま。

クリーンアップ:
```bash
pkill -x ide 2>/dev/null
rm -rf /tmp/ide-step3-test
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

### 14. アトミック書き込み・バックアップ世代（手動）

実機で確認:
- ピン留めを 4 回切り替える
- `ls "$HOME/Library/Application Support/ide/"` で `projects.json` `.1` `.2` `.3` が並ぶ
- ピン留め中に強制終了させても `projects.json` か `.1` が読み取れること

### 15. 「再選択」メニュー（手動）

実機で確認:
- missing 状態の行を右クリック → 「再選択…」が出る
- 選ぶと NSOpenPanel が開く
- 別のフォルダを選ぶと displayName とアイコンが復活する
- アプリを再起動してもパスが永続化されている

### 16. プロジェクトごとのターミナル + cwd（自動）

`IDE_TEST_AUTO_ACTIVATE_INDEX` で起動時に N 番目のピン留めを active にできる（デバッグ用フラグ。本番では使わない）。

```bash
pkill -x ide 2>/dev/null
mkdir -p "$HOME/Library/Application Support/ide"
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"Documents","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/Users/d0ne1s/Documents"}
  ],
  "schemaVersion" : 1
}
JSON
APP=/tmp/ide-build/Build/Products/Debug/ide.app

# index=0 で ide を active 起動 → cwd が /Users/d0ne1s/ide のターミナル
IDE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 2
./scripts/ide-screenshot.sh /tmp/v-step4-ide-term.png
grep "surface\] new" /tmp/ide-poc.log | tail -2
pkill -x ide 2>/dev/null; sleep 0.4

# index=1 で Documents を active 起動 → cwd が /Users/d0ne1s/Documents のターミナル
IDE_TEST_AUTO_ACTIVATE_INDEX=1 "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 2
./scripts/ide-screenshot.sh /tmp/v-step4-documents.png
grep "surface\] new" /tmp/ide-poc.log | tail -2
```

期待:
- ide active 時のスクショで右ペインのプロンプトに `~/ide main !` が出る（cwd が /Users/d0ne1s/ide）
- Documents active 時のスクショでプロンプトに `~/Documents` が出る
- ログに `[surface] new ok cwd=...` が project に応じて変わる
- 中央ペインに active project の名前とパスが表示される

クリーンアップ:
```bash
pkill -x ide 2>/dev/null
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

### 17. プロジェクト切替の状態保持（手動）

実機で確認（要件「ターミナルセッションは生きっぱなし」）:
- ide active のターミナルで `echo from-ide` を実行
- 左サイドバーで Documents をクリック → ターミナル切替（cwd が変わる）
- もう一度 ide をクリック → 前の echo 出力が見える、新しい login 行は出ない
- ide のターミナルで `claude` を起動して回しっぱなしにする → Documents に切り替えても claude は動き続ける（プロセス的に kill されない）

### 18. Ctrl+M MRU 切替オーバーレイ（自動）

要件: TUI（vim/claude）内でも例外なく IDE が捕捉。逃がし手段はなし。

```bash
mkdir -p "$HOME/Library/Application Support/ide"
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"Documents","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/Users/d0ne1s/Documents"}
  ],
  "schemaVersion" : 1
}
JSON
pkill -x ide 2>/dev/null; sleep 0.4
APP=/tmp/ide-build/Build/Products/Debug/ide.app
IDE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/ide" >/tmp/ide-stdout.log 2>&1 &
sleep 2
```

#### 18-A. ターミナル上で Ctrl+M

```bash
# Ctrl 押しっぱなしで M を 1 回 → オーバーレイ表示
osascript <<'OSA'
tell application "System Events"
  tell process "ide"
    set frontmost to true
    delay 0.3
    key down control
    delay 0.05
    key code 46  -- M
    delay 0.05
  end tell
end tell
OSA
sleep 0.2
./scripts/ide-screenshot.sh /tmp/v-step5-overlay.png
osascript -e 'tell application "System Events" to key up control'
sleep 0.4
./scripts/ide-screenshot.sh /tmp/v-step5-after-commit.png
```

期待:
- overlay スクショで中央に半透明パネル、ide / Documents の 2 件が並び、Documents（直前=MRU 2 番目）が青ハイライト
- after-commit スクショで Documents が active（左サイドバーで青ハイライト、右ペインの cwd が `~/Documents`）

#### 18-B. vim 起動中に Ctrl+M

```bash
./scripts/ide-keystroke.sh --enter "vim README.md"
sleep 1.5
osascript <<'OSA'
tell application "System Events"
  tell process "ide"
    set frontmost to true
    delay 0.3
    key down control
    delay 0.05
    key code 46
    delay 0.05
  end tell
end tell
OSA
sleep 0.2
./scripts/ide-screenshot.sh /tmp/v-step5-vim-overlay.png
osascript -e 'tell application "System Events" to key up control'
```

期待: vim 編集中でも overlay が表示される（vim 側に CR は届かない=改行されない）。

#### 18-C. Esc キャンセル

```bash
# Documents が active の状態から
osascript <<'OSA'
tell application "System Events"
  tell process "ide"
    set frontmost to true
    delay 0.3
    key down control
    delay 0.05
    key code 46    -- M
    delay 0.05
    key code 53    -- Esc
    delay 0.05
  end tell
end tell
OSA
osascript -e 'tell application "System Events" to key up control'
sleep 0.4
./scripts/ide-screenshot.sh /tmp/v-step5-after-esc.png
```

期待: Documents が active のまま（Esc で active 不変、MRU も不変）。

クリーンアップ:
```bash
pkill -x ide 2>/dev/null
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

### 19. Ctrl+M 連打サイクル（手動）

実機で確認:
- 3 つ以上のプロジェクトを開いて MRU を貯める（A → B → C と順に active 化）
- A active の状態で **Ctrl 押しっぱなしで M 連打**
  - 1 回目: B にカーソル（直前）
  - 2 回目: C にカーソル
  - 3 回目: A にカーソル（一周）
- Ctrl 離した瞬間に確定 → 選んでた project が active になる

### 20. ファイルツリー基本表示（自動）

```bash
mkdir -p "$HOME/Library/Application Support/ide"
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}
  ],
  "schemaVersion" : 1
}
JSON
pkill -x ide 2>/dev/null; sleep 0.4
APP=/tmp/ide-build/Build/Products/Debug/ide.app
IDE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/ide" >/tmp/ide-stdout.log 2>&1 &
sleep 2.5
./scripts/ide-screenshot.sh /tmp/v-step6-tree.png
```

期待:
- 中央ペインに ide リポジトリの直下子（フォルダ先・アルファベット順）が表示
  - .git / .refs / docs / GhosttyKit.xcframework / ide.xcodeproj / Resources / scripts / Sources
  - .gitignore / .mise.toml / project.yml / REQUIREMENTS.md / VERIFY.md
- 各ディレクトリの左に展開 chevron（▶）
- 拡張子別アイコン: .md = 紫の doc.richtext、.toml/.yml = doc.text、folder = 青
- ツールバー: tree アイコン + プロジェクト名 + 👁 (gitignore 表示トグル) + 🔄 (reload)

クリーンアップ:
```bash
pkill -x ide 2>/dev/null
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

### 21. ファイルツリー展開・右クリック（手動）

実機で確認（座標 click が SwiftUI の onTapGesture に届かないため自動不可）:
- ディレクトリの ▶ chevron か行をクリック → 子要素が展開（lazy scan で初回のみ僅かに遅延）
- もう一度クリックで折り畳み
- `.gitignore` 対象（例: `Sources/ide/build` や `.refs/`）が薄表示になっている
- 👁 ボタンを押すと gitignore 対象が完全非表示になる、もう一度押すと薄表示に戻る
- 🔄 ボタンを押すと再スキャンされる（変更が反映される）
- ファイルを右クリック → 「相対パスをコピー」「ターミナルで開く」
  - 相対パスをコピー: pasteboard に project root からの相対パスが入る
  - ターミナルで開く: 暫定実装（pasteboard に `cd <絶対パス>\n` が入る、step8 以降で active terminal に直接送る予定）

### 22. シンボリックリンクの扱い（手動）

実機で確認:
- ディレクトリ symlink（例: `.refs/cmux` のような external clone）は中身を辿らず、矢印 → リンク先パスが表示される
- ファイル symlink は通常のファイルとして表示、矢印で target も併記

### 23. git status バッジ（自動）

```bash
mkdir -p "$HOME/Library/Application Support/ide"
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
echo "<!-- step7 test marker -->" >> /Users/d0ne1s/ide/VERIFY.md
pkill -x ide 2>/dev/null; sleep 0.4
APP=/tmp/ide-build/Build/Products/Debug/ide.app
IDE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/ide" >/tmp/ide-stdout.log 2>&1 &
sleep 4
./scripts/ide-screenshot.sh /tmp/v-step7-modified.png
pkill -x ide 2>/dev/null
git -C /Users/d0ne1s/ide checkout -- VERIFY.md
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

期待: スクショで VERIFY.md の右端に青い `M` バッジが見える（modified ステータス、3 秒 polling で更新）。

### 24. ファイルツリー差分反映（手動 / Phase 2.5）

要件「fs watcher でツリー差分反映」は Phase 2.5 で導入予定。MVP では手動 reload で代替:
- ターミナルで新規ファイル `touch newfile.txt` を作成
- ツリーには即時反映されない（FSEvents 未統合）
- ツリー右上の 🔄 ボタンを押すと再スキャンされて新規ファイルが現れる
- 新規ファイルなら `?` バッジが付く（次の git status polling サイクル後）

### 25. ファイルプレビュー（自動）

`IDE_TEST_AUTO_PREVIEW` 環境変数で起動時に project root からの相対パスを開ける。

```bash
mkdir -p "$HOME/Library/Application Support/ide"
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
APP=/tmp/ide-build/Build/Products/Debug/ide.app

# Markdown
pkill -x ide 2>/dev/null; sleep 0.4
IDE_TEST_AUTO_ACTIVATE_INDEX=0 IDE_TEST_AUTO_PREVIEW="REQUIREMENTS.md" "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 3
./scripts/ide-screenshot.sh /tmp/v-step8-md.png

# Swift コード
pkill -x ide 2>/dev/null; sleep 0.4
IDE_TEST_AUTO_ACTIVATE_INDEX=0 IDE_TEST_AUTO_PREVIEW="Sources/ide/IdeApp.swift" "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 3
./scripts/ide-screenshot.sh /tmp/v-step8-swift.png

# XML (Info.plist)
pkill -x ide 2>/dev/null; sleep 0.4
IDE_TEST_AUTO_ACTIVATE_INDEX=0 IDE_TEST_AUTO_PREVIEW="Resources/Info.plist" "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 3
./scripts/ide-screenshot.sh /tmp/v-step8-plist.png
pkill -x ide 2>/dev/null
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

期待:
- 中央ペインがプレビューモードに切替（ツールバー左に `folder` アイコン + `/` + ファイル名のパンくず、続いて履歴ナビ ← →、右端に「VSCode で開く」）
- Markdown はインラインレンダリング（リンク・強調が効く、見出しはプレーン）
- コード（.swift）はモノスペースで表示
- XML はそのままプレーンテキスト

### 26. プレビュー画像/PDF/バイナリ/大きいファイル（手動）

実機で確認:
- **画像**: ツリーから .png/.jpg などをクリック → ScrollView 内に画像が表示
- **PDF**: .pdf をクリック → PDFKit で表示、ページめくり可
- **バイナリ**: 実行可能ファイル等を選択 → 「バイナリファイルです（プレビュー非対応）」+「VSCode で開く」ボタン
- **5MB 〜 50MB**: 「N MB のファイルです。読み込みますか？」確認 → 「読み込む」でテキスト表示
- **50MB 超**: 自動的に「外部で開いてください」+「VSCode で開く」
- **Cmd+Option+O**: VSCode が起動し、当該ファイルが開く
- **Esc / `folder` アイコンパンくず**: ツリーに戻る（ホバーで primary 色に変化）

### 27. プレビュー履歴ナビ（手動）

実機で確認:
- ツリー → ファイル A をクリック → プレビュー A を表示、ツールバーの ← → は両方 disable
- ファイル B をクリック → プレビュー B、← が enable、→ は disable
- ← をクリック → A に戻る、→ が enable に
- → をクリック → B に進む
- 同じファイルを連続でクリックしても履歴は重複しない（A → A → B → A の操作で履歴は A → B → A の 3 件）

### 28. Cmd+P クイック検索（自動）

```bash
mkdir -p "$HOME/Library/Application Support/ide"
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
APP=/tmp/ide-build/Build/Products/Debug/ide.app
pkill -x ide 2>/dev/null; sleep 0.4
IDE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 3
osascript <<'OSA'
tell application "System Events"
  tell process "ide"
    set frontmost to true
    delay 0.3
    keystroke "p" using {command down}
    delay 0.4
    keystroke "Read"
    delay 0.5
  end tell
end tell
OSA
./scripts/ide-screenshot.sh /tmp/v-step10-read.png
pkill -x ide 2>/dev/null
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

期待: 中央上部にオーバーレイが表示され、検索結果の一番上に `REQUIREMENTS.md` が出る。

### 29. Cmd+P 操作（手動）

実機で確認:
- Cmd+P でオーバーレイ起動
- ↓↑ で選択を移動
- Enter で選んだファイルを preview に開く
- Esc でキャンセル
- スラッシュを含むクエリ（例: `sources/i`）はパスマッチに自動切替で精度が変わる

### 30. Cmd+Shift+F 全文検索（自動）

`IDE_TEST_AUTO_FULLSEARCH` で起動時に grep を実行できる。

```bash
mkdir -p "$HOME/Library/Application Support/ide"
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
APP=/tmp/ide-build/Build/Products/Debug/ide.app
pkill -x ide 2>/dev/null; sleep 0.4
IDE_TEST_AUTO_ACTIVATE_INDEX=0 IDE_TEST_AUTO_PREVIEW="REQUIREMENTS.md" IDE_TEST_AUTO_FULLSEARCH="Project" "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 4
./scripts/ide-screenshot.sh /tmp/v-step11-search.png
pkill -x ide 2>/dev/null
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

期待: スクショで `Project` の検索結果が複数件並ぶ（VERIFY.md / phase2-files.md / MRUKeyMonitor.swift など）。各行にファイル名 + 行番号 + プレビュー。

### 31. Cmd+Shift+F 操作（手動）

実機で確認:
- Cmd+Shift+F でオーバーレイ起動
- 文字を入力して Enter で検索実行（AppleScript 経由では onSubmit が効かないので手動必須）
- ↑↓ で結果選択、Enter / クリックで preview 切替
- Esc でキャンセル

### 32. プロジェクト一覧のドラッグ並び替え（手動 / 半自動）

要件: pinned / temporary とも手動で並び替え可能、両方とも順序が永続化される。pinned↔temporary を跨いだら自動で pin/unpin される。

#### 32-A. 手動

実機で確認:
- 行を上下にドラッグ → 別の行に重ねた状態で離すと、その行の上半分なら「前に挿入」、下半分なら「後ろに挿入」
- ドラッグ中、対象行の上 or 下に青いバーが出る（drop indicator）
- セクション末尾の隙間にドロップ → そのセクションの末尾に追加
- pinned から temporary 区切りの下にドロップ → 自動で unpin（regular weight に変わる）
- temporary から pinned 区切りの上にドロップ → 自動で pin（semibold に変わる）
- 並び替え後にアプリ再起動 → 順序が維持される
- pinned で active にしている行を unpin にドラッグしてもアクティブのまま（中央/右ペインは不変）

#### 32-B. 半自動（CGEvent でドラッグを合成）

`.draggable` / `.dropDestination` は AppleScript の click では発火しないが、`CGEvent` でマウスダウン → 数十ステップの drag → アップを合成すれば動く。

```bash
# ドラッグ合成 CLI を一時的にコンパイル
cat > /tmp/simulate-drag.swift <<'SWIFT'
import Cocoa
import CoreGraphics
let args = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let from = CGPoint(x: args[0], y: args[1])
let to = CGPoint(x: args[2], y: args[3])
func post(_ t: CGEventType, at p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved, at: from); usleep(200_000)
post(.leftMouseDown, at: from); usleep(300_000)
let prefix = CGPoint(x: from.x + 5, y: from.y + 5)
post(.leftMouseDragged, at: prefix); usleep(100_000)
for i in 1...40 {
    let t = Double(i) / 40
    post(.leftMouseDragged, at: CGPoint(x: prefix.x + (to.x-prefix.x)*t, y: prefix.y + (to.y-prefix.y)*t))
    usleep(20_000)
}
usleep(300_000); post(.leftMouseUp, at: to)
SWIFT
swiftc -o /tmp/simulate-drag /tmp/simulate-drag.swift

# テスト fixture（5 件、alpha/bravo を pinned）
pkill -x ide 2>/dev/null; sleep 0.4
mkdir -p "$HOME/Library/Application Support/ide" /tmp/ide-dnd-test/{alpha,bravo,charlie,delta,echo}
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"alpha","id":"AAAAAAAA-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/tmp/ide-dnd-test/alpha"},
    {"displayName":"bravo","id":"BBBBBBBB-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/tmp/ide-dnd-test/bravo"},
    {"displayName":"charlie","id":"CCCCCCCC-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"/tmp/ide-dnd-test/charlie"},
    {"displayName":"delta","id":"DDDDDDDD-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T04:00:00Z","path":"/tmp/ide-dnd-test/delta"},
    {"displayName":"echo","id":"EEEEEEEE-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T05:00:00Z","path":"/tmp/ide-dnd-test/echo"}
  ],
  "schemaVersion" : 1
}
JSON
./scripts/ide-launch.sh
sleep 0.8

# 座標は launch 後の osascript "position of front window" で取得した window 左上が (179, 154) のときのもの。
# alpha 中心 ≈ (249, 246)、echo 中心 ≈ (249, 371)、echo 下半分 ≈ (249, 385)
# alpha → echo 下半分にドラッグ = 自動で unpin、temp 末尾に移動
/tmp/simulate-drag 249 246 249 385
sleep 0.6
python3 -c "
import json
d = json.load(open('$HOME/Library/Application Support/ide/projects.json'))
for p in d['projects']: print(f\"  {p['displayName']}: pinned={p['isPinned']}\")
"

pkill -x ide 2>/dev/null
rm -f /tmp/simulate-drag /tmp/simulate-drag.swift
rm -rf /tmp/ide-dnd-test
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

期待出力:
```
  bravo: pinned=True
  charlie: pinned=False
  delta: pinned=False
  echo: pinned=False
  alpha: pinned=False
```

座標は実機のウィンドウ位置によって変わる。`./scripts/ide-launch.sh` 後に AppleScript で取得した window 位置 + 行高さ 28pt を加算して計算する。

#### 32-C. setActive で MRU 並び替えしないことの確認（自動）

旧仕様では temporary を active 化すると先頭に移動していたが、ドラッグ並び替え導入で廃止した（手動順序を尊重）。

```bash
mkdir -p "$HOME/Library/Application Support/ide" /tmp/ide-dnd-test/{a,b,c}
cat > "$HOME/Library/Application Support/ide/projects.json" <<'JSON'
{"projects":[
  {"displayName":"a","id":"AAAAAAAA-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/tmp/ide-dnd-test/a"},
  {"displayName":"b","id":"BBBBBBBB-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/tmp/ide-dnd-test/b"},
  {"displayName":"c","id":"CCCCCCCC-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"/tmp/ide-dnd-test/c"}
],"schemaVersion":1}
JSON
pkill -x ide 2>/dev/null; sleep 0.4
APP=/tmp/ide-build/Build/Products/Debug/ide.app
# 末尾の c を active 化しても順序は a, b, c のまま（旧仕様だと c が先頭になる）
IDE_TEST_AUTO_ACTIVATE_INDEX=2 "$APP/Contents/MacOS/ide" >/dev/null 2>&1 &
sleep 2
pkill -x ide 2>/dev/null; sleep 0.4
python3 -c "
import json
d = json.load(open('$HOME/Library/Application Support/ide/projects.json'))
print(','.join(p['displayName'] for p in d['projects']))
"
rm -rf /tmp/ide-dnd-test
rm -f "$HOME/Library/Application Support/ide/projects.json"*
```

期待出力: `a,b,c`（c が先頭に移動していない）。
