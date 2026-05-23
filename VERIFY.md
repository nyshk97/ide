# 動作確認

実装・修正後に動作を確認するための手順集。変更内容に応じて関係する項目だけ実行する（毎回全部やらない）。

## 前提

- 開発ビルドは `mise run build`（XcodeGen による `regen` を内包）
- `.app` の出力先は `/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app`（Debug は Bundle ID `local.d0ne1s.polepole.dev` / PRODUCT_NAME `PolePole Dev` で Release と完全分離）
- 動作確認用ヘルパは `scripts/` 配下:
  - `scripts/polepole-launch.sh [wait_seconds]` — kill + open + 起動待ち
  - `scripts/polepole-keystroke.sh [--enter|--keycode N] "text"` — `osascript` でキーストローク送信
  - `scripts/polepole-screenshot.sh <output_path>` — フロントウィンドウ領域をキャプチャ

ログは `/tmp/polepole-poc.log`（init() で reset）に書き出される。`tail -f /tmp/polepole-poc.log` で追える。

## ⚠️ projects.json を触る検証は事前バックアップを推奨

以下のセクションは `~/Library/Application Support/polepole-dev/projects.json` をテスト用フィクスチャで上書きし、最後に `rm -f` で消します。Debug ビルドの Bundle ID は `.dev` suffix で分離されており、Brew 配布版が使う `~/Library/Application Support/polepole/projects.json` には触らない設計です。とはいえ Dev 版でも普段からピン留めしているデータがあるなら、念のためバックアップを取っておくのが安全:

```bash
# 検証開始前
BACKUP_DIR=$(mktemp -d)
cp -a "$HOME/Library/Application Support/polepole-dev/" "$BACKUP_DIR/polepole-dev-backup" 2>/dev/null || true

# 検証完了後
rm -rf "$HOME/Library/Application Support/polepole-dev"
mv "$BACKUP_DIR/polepole-dev-backup" "$HOME/Library/Application Support/polepole-dev" 2>/dev/null || true
```

**Release configuration で起動して検証するケース**（`build.sh` 経由の `.app` を `/Applications/` に入れて確認するなど）では `ide/projects.json` を直接扱うので、その場合は退避先を `ide-backup` にして `ide/` 配下を保護してください。

対象セクション: 13, 14, 16, 17, 19, 23, 25, 28, 30 など `cat > .../projects.json` を含む全節。

---

## 1. ビルドと起動

```bash
mise run build
./scripts/polepole-launch.sh
```

期待: `** BUILD SUCCEEDED **` と表示され、ide ウィンドウが前面に開く。

ログ確認:
```bash
cat /tmp/polepole-poc.log
```
期待出力に `[ghostty] init=0`、`[ghostty] app_new ok`、`[surface] new ok` が含まれる。

## 2. ターミナル基本動作

```bash
./scripts/polepole-launch.sh
./scripts/polepole-keystroke.sh --enter "echo hello && pwd"
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-basic.png
```

スクショに `hello` の出力と HOME 相当のパスが表示されていること。

## 3. リサイズ追従

```bash
./scripts/polepole-launch.sh
osascript -e 'tell application "System Events" to tell process "ide" to set size of front window to {1300, 800}'
sleep 0.3
./scripts/polepole-keystroke.sh --enter "stty size"
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-resize.png
```

`stty size` の出力（行 列）がウィンドウサイズに見合った値に変わっていること（PTY rows/cols が同期している）。

## 4. Ghostty 設定継承

```bash
./scripts/polepole-launch.sh
grep "diag\[" /tmp/polepole-poc.log
```

`~/.config/ghostty/config` に設定ミスがあれば diagnostic が出る。または UI 上で自分の Ghostty 設定どおりのフォント・カラースキームになっていること。

## 5. 256色・True Color

```bash
./scripts/polepole-launch.sh
./scripts/polepole-keystroke.sh --enter "for i in {0..15}; do for j in {0..15}; do printf \"\\x1b[48;5;\$((i*16+j))m  \\x1b[0m\"; done; printf \"\\n\"; done"
sleep 0.5
./scripts/polepole-keystroke.sh --enter "for i in {0..127}; do printf \"\\x1b[48;2;\$((i*2));\$((255-i*2));128m \\x1b[0m\"; done; printf \"\\n\""
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-color.png
```

スクショに 16x16 の 256 パレットと、24bit RGB のなめらかなグラデーションが映っていること。

## 6. URL リンク化

```bash
./scripts/polepole-launch.sh
./scripts/polepole-keystroke.sh --enter "echo https://example.com"
```

実機で:
- 出力中の URL をマウスホバー → 下線が出る（Ghostty 標準動作）
- `Cmd+クリック` で Safari が開く
- `file://` 等は ide 側で弾く（無視）

## 7. AI 種別バッジ

```bash
./scripts/polepole-launch.sh
osascript -e 'tell application "System Events" to tell process "ide" to set frontmost to true'
sleep 0.3
osascript -e 'tell application "System Events" to key code 102'
./scripts/polepole-keystroke.sh --enter "claude"
sleep 4
./scripts/polepole-screenshot.sh /tmp/v-ai-badge.png
```

期待: タブ名「shell 1」の左に 🅒 アイコン（オレンジ tint）が出る。Esc で claude を抜けるとアイコンが消える。

`codex` 起動時は 🅞（緑 tint）が出る。識別は `proc_pidpath` の basename から拡張子を除いて行う。注意点:

- claude のバイナリは bun SEA で `proc_pidpath` が空を返すため `procComm` フォールバック（16文字制限の `claude` / `claude.exe`）にマッチする
- Homebrew cask 経由の codex は `/opt/homebrew/Caskroom/codex/<ver>/codex-aarch64-apple-darwin` を `proc_pidpath` が返すので、basename は `codex-aarch64-apple-darwin` になる。`baseNoExt == "codex" || baseNoExt.hasPrefix("codex-")` で拾う

## 7. AI 完了通知（タブ青丸バッジ + サイドバーのリング）

claude / codex は応答中に `OSC 9;4` プログレス（INDETERMINATE 等）を出し、ターンが終わると REMOVE で消す。PolePole は **「`.claude`/`.codex` タブで 作業中 → REMOVE の遷移」を「応答完了」とみなして**、そのタブがバックグラウンド（active pane の active tab でない）なら未読を立てる。BEL（`\a`）や OSC 9 / OSC 777 のデスクトップ通知も同様に未読のトリガーになる（が claude/codex は実際には鳴らさず、主経路はプログレス）。未読が立つと:
- そのタブ → タブ名の右に青丸（●）バッジ
- そのプロジェクト → サイドバーのアバターに青いリング（配下のどれかのタブが未読なら点灯。表示中のタブをアクティブにすると消える）

調査用に `/tmp/polepole-poc.log` に `[progress]`（プログレス受信）/ `[unread]`（未読を立てた）ログを出している。

### 7-a. サイドバーのリング（自動・決定的）

`POLEPOLE_TEST_UNREAD_INDICES=0,2` で起動時に 0 番目と 2 番目のプロジェクトの下ペインのタブに未読を仕込める。

```bash
pkill -x "PolePole Dev" 2>/dev/null
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-10T01:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"docs","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-10T02:00:00Z","path":"/Users/d0ne1s/ide/docs"},
    {"displayName":"Sources","id":"33333333-3333-3333-3333-333333333333","isPinned":true,"lastOpenedAt":"2026-05-10T03:00:00Z","path":"/Users/d0ne1s/ide/Sources"}
  ],
  "schemaVersion" : 1
}
JSON

# index 1 (docs) をアクティブ起動。0/2 を未読に。
open -n "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app" \
  --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=1 --env POLEPOLE_TEST_UNREAD_INDICES=0,2
sleep 4
./scripts/polepole-screenshot.sh /tmp/v-ring.png
```

期待:
- サイドバーで `ide`（index 0）と `Sources`（index 2）のアバターに青いリングが付く
- `docs`（index 1 = active）にはリングが付かない

次に「未読プロジェクトをアクティブにすると、その表示タブの未読が消える」確認:

```bash
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.5
# 今度は index 0 (ide) を未読にしつつアクティブ起動
open -n "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app" \
  --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 --env POLEPOLE_TEST_UNREAD_INDICES=0,2
sleep 4
./scripts/polepole-screenshot.sh /tmp/v-ring-activated.png
```

期待: `ide` はアクティブ行になり**リング無し**（表示中の下ペインのタブの未読がクリアされた）、`Sources` はリングが残る。

クリーンアップ:
```bash
pkill -x "PolePole Dev" 2>/dev/null
rm -rf "$HOME/Library/Application Support/polepole-dev"
```

### 7-b. 実機での確認（claude / codex 実セッション）

1. 適当なプロジェクトを開いて、下ペインで `claude`（or `codex`）を起動
2. プロンプトを投げて、すぐ Cmd+T で別タブに移る（AI タブをバックグラウンドに）
3. 応答が終わると → AI タブに青丸、サイドバーのプロジェクトにリング。`grep '\[unread\]' /tmp/polepole-poc.log` に `reason=ai-turn-done` が出る
4. その AI タブ / ペインをクリックで切替 → 青丸が消える。プロジェクト配下の未読が全部消えたらリングも消える
5. AI タブを active にしたまま応答完了 → 出ない（自分で見ているので未読扱いしない。`[progress]` ログには `state=0` が出るが `[unread]` は出ない）
6. 素のシェルで `printf '\a'` → 出ない（AI タブでないため）

## 7. PTY 異常終了表示と再起動

```bash
./scripts/polepole-launch.sh
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
./scripts/polepole-launch.sh
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
./scripts/polepole-keystroke.sh --enter "tty"
```
を上下それぞれで打って異なる TTY が出ることを確認（手動でアクティブ切替後、各ペインで実行）。

## 7. 複数タブ

```bash
./scripts/polepole-launch.sh
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
./scripts/polepole-screenshot.sh /tmp/v-tabs.png
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
./scripts/polepole-screenshot.sh /tmp/v-tabs-close.png
```

期待: shell 2 が閉じて shell 1 だけ残り、shell 1 のバッファ（`tab-1` 出力）が保持されている。

## 7. IME（日本語入力）

入力ソースが日本語のとき、AppleScript で英字を打つとライブ変換が走る:
```bash
./scripts/polepole-launch.sh
osascript -e 'tell application "System Events" to keystroke "echo"'  # IME が日本語ローマ字なら「えちょ」になる
```
→ ターミナル上で preedit が表示される（赤文字 = zsh-syntax-highlighting でコマンド未存在判定）= `setMarkedText` → `ghostty_surface_preedit` 経路が動作。

英数モードに戻して ASCII 入力が壊れていないか:
```bash
./scripts/polepole-launch.sh
osascript -e 'tell application "System Events" to key code 102'  # 英数キー
./scripts/polepole-keystroke.sh --enter "echo ascii-after-eisuu"
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-ime-ascii.png
```

実機での日本語確認（手動）:
- 入力ソースを日本語に切替 → ide にフォーカス
- 「あ」と打って preedit が出る、Space で変換、Enter で確定 → ターミナルに「あ」が入る

## 7. マウス（手動確認）

```bash
./scripts/polepole-launch.sh
./scripts/polepole-keystroke.sh --enter "for i in {1..80}; do echo \"line \$i\"; done"
```

以下を実機で確認:
- マウスホイールで上下スクロールができる
- ドラッグでテキスト選択、選択範囲がハイライトされる
- 選択後 `Cmd+C` でクリップボードへコピーされる（`pbpaste` で確認）
- `vim` 起動後、マウスホイールでバッファスクロールできる

## 7. クリップボードペースト

```bash
echo "expected-payload-$(date +%s)" | tr -d '\n' | pbcopy
./scripts/polepole-launch.sh
./scripts/polepole-keystroke.sh "echo "
osascript -e 'tell application "System Events" to keystroke "v" using command down'
sleep 0.3
./scripts/polepole-keystroke.sh --keycode 36
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-paste.png
```

スクショの出力に `pbcopy` で渡した文字列が映っていること。ログ確認:
```bash
grep "\[clip\]" /tmp/polepole-poc.log
```

## 8. TUI 動作確認

### vim

```bash
./scripts/polepole-launch.sh
./scripts/polepole-keystroke.sh --enter "vim REQUIREMENTS.md"
sleep 1.5
./scripts/polepole-screenshot.sh /tmp/v-vim.png
./scripts/polepole-keystroke.sh ":q!"
./scripts/polepole-keystroke.sh --keycode 36  # Enter
```

スクショで Markdown のシンタックスハイライト・罫線文字・ステータスラインが正しく描画されていること。

### fzf

```bash
./scripts/polepole-keystroke.sh --enter "ls | fzf --height=50%"
sleep 1
./scripts/polepole-screenshot.sh /tmp/v-fzf.png
./scripts/polepole-keystroke.sh --keycode 53  # Esc
```

ファイル一覧が表示され、カーソル行がハイライトされ、`N/N` のステータスが見えること。

### claude

```bash
./scripts/polepole-keystroke.sh --enter "claude"
sleep 4
./scripts/polepole-screenshot.sh /tmp/v-claude.png
./scripts/polepole-keystroke.sh --keycode 53  # Esc
```

claude code の起動画面（信頼確認やプロンプト入力欄）が崩れずに描画されること。

---

## Phase 2

### 9. 3カラムレイアウト

```bash
./scripts/polepole-launch.sh
./scripts/polepole-screenshot.sh /tmp/v-3col.png
./scripts/polepole-keystroke.sh --enter "echo phase2-step1-ok && pwd"
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-3col-terminal.png
```

期待:
- スクショに 3 カラム（左 `Projects` / 中央 `Tree / Preview` / 右 ターミナル）が表示される
- 右ペインは上下 2 タブ（VSplitView）が引き続き動作
- `echo phase2-step1-ok` の出力が右ペインのアクティブターミナルに表示される

実機での手動確認:
- 左サイドバーと中央ペインの境界をドラッグで動かせる
- 中央ペインと右ペインの境界をドラッグで動かせる
- ウィンドウ最小幅は 1000px（それ以下に縮められない）

#### 9-a. 初期比率 (center : right = 2 : 3) と autosave 永続化

過去に何度も壊した箇所。回帰しやすいので必ず確認する。詳細は [docs/DEV.md の SwiftUI まわりのクセ](docs/DEV.md#swiftui-まわりのクセ) を参照。

```bash
# autosave をクリアして初回起動を再現する
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.5
defaults delete local.d0ne1s.polepole.dev "NSSplitView Subview Frames ide.rootSplit" 2>/dev/null || true
./scripts/polepole-launch.sh && sleep 2
echo "--- 初期 divider 位置 ---"
defaults read local.d0ne1s.polepole.dev "NSSplitView Subview Frames ide.rootSplit"
```

期待 (1000pt ウィンドウ):
```
(
    "0.000000, 0.000000, 140.000000, ..., NO, NO",   ← left = 140
    "141.000000, 0.000000, 343.000000, ..., NO, NO", ← center = 343
    "485.000000, 0.000000, 515.000000, ..., NO, NO"  ← right = 515
)
```

判定:
- left = 140 (`leftInitial` と一致)
- `center : right = 343 : 515 ≈ 40 : 60` (= 2 : 3)
- ウィンドウ幅が変わっても比率が同じ (= 残り幅 × 0.4 / × 0.6)

ありがちな fail パターン:
- left = 120 (= 最小幅にクランプ): `userHasDragged` 検知が起動直後に勝手に true になっている → `DragDetectingSplitView.mouseDown` の divider 矩形判定を疑う
- center が極端に狭い / 広い: `viewDidLayout` で初期比率を 1 回だけセットして固定している → 中間サイズで先に発火している。`didSetInitial` で 1 回ロックする実装に戻したら NG
- 結果が出ない / 値が変: `defaults` 読み出し前に PolePole Dev が完全終了していない (autosave は quit 時に書き出される) → `pkill` のあとに数秒待ってから読み直す

ドラッグ位置の永続化確認 (手動):
1. divider をドラッグして任意の位置に動かす
2. `pkill -x "PolePole Dev" && sleep 1 && ./scripts/polepole-launch.sh`
3. ドラッグした位置が復元されること

### 10. プロジェクト追加（インメモリ・自動）

```bash
./scripts/polepole-launch.sh
./scripts/polepole-screenshot.sh /tmp/v-step2-empty.png
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
./scripts/polepole-screenshot.sh /tmp/v-step2-3rows.png
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

`~/Library/Application Support/polepole-dev/projects.json` には pinned / temporary 両方が保存され、再起動でサイドバーに復元される（明示的に「閉じる」した時のみ消える）。

```bash
pkill -x "PolePole Dev" 2>/dev/null
mkdir -p "$HOME/Library/Application Support/polepole-dev"
mkdir -p /tmp/polepole-step3-test/willmove /tmp/polepole-step3-test/temp-proj
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"willmove","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/tmp/polepole-step3-test/willmove"},
    {"displayName":"temp-proj","id":"33333333-3333-3333-3333-333333333333","isPinned":false,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"/tmp/polepole-step3-test/temp-proj"}
  ],
  "schemaVersion" : 1
}
JSON
./scripts/polepole-launch.sh
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-step3-restored.png
```

期待: ピン留めセクションに ide / willmove が並ぶ（ボールド表示）、その下に区切り線 → 一時セクションに temp-proj が出る（レギュラー表示）、中央ペインに「左からプロジェクトを選択」。

temporary が永続化されている確認（自動）:
```bash
pkill -x "PolePole Dev" 2>/dev/null
sleep 0.5
# allOrdered の index 2（pinned 2件 + temporary 1件目 = temp-proj）をアクティブ化
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=2 /tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev >/tmp/polepole-stdout.log 2>&1 &
sleep 3
# temp-proj の lastOpenedAt が更新されていれば temporary も永続化されている
python3 -c "import json; d=json.load(open('$HOME/Library/Application Support/polepole-dev/projects.json')); [print(f\"{p['displayName']}: {p['lastOpenedAt']}\") for p in d['projects']]"
pkill -x "PolePole Dev" 2>/dev/null
```

期待: temp-proj の lastOpenedAt が `2026-05-09T03:00:00Z` から起動時刻に更新されている。

### 13. missing 状態（自動）

```bash
pkill -x "PolePole Dev" 2>/dev/null
mv /tmp/polepole-step3-test/willmove /tmp/polepole-step3-test/moved-away
./scripts/polepole-launch.sh
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-step3-missing.png
```

期待: willmove が黄色 ⚠ アイコン + 半透明で表示、ide は通常表示のまま。

クリーンアップ:
```bash
pkill -x "PolePole Dev" 2>/dev/null
rm -rf /tmp/polepole-step3-test
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

### 13-a. missing なプロジェクトは active にできない（半自動）

要件 2「クリックしても開けない」。`POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` で missing なプロジェクトを active にしようとして、toast が出るだけで workspace（shell）が作られないことを確認する。

```bash
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
SUPPORT="$HOME/Library/Application Support/polepole-dev"
BACKUP_DIR=$(mktemp -d); [ -d "$SUPPORT" ] && cp -a "$SUPPORT" "$BACKUP_DIR/polepole-dev-backup"
mkdir -p "$SUPPORT"
cat > "$SUPPORT/projects.json" <<'JSON'
{ "schemaVersion": 1, "projects": [
  { "id": "00000000-0000-0000-0000-000000000001", "displayName": "ghost-project", "isPinned": true, "lastOpenedAt": "2026-05-01T00:00:00Z", "path": "/tmp/nonexistent-project-p14" }
] }
JSON
pkill -x "PolePole Dev" 2>/dev/null; sleep 1
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 4
grep -n "見つかりません\|workspace\|WorkspaceModel" /tmp/polepole-poc.log
pkill -x "PolePole Dev" 2>/dev/null; sleep 1
rm -rf "$SUPPORT"; [ -d "$BACKUP_DIR/polepole-dev-backup" ] && mv "$BACKUP_DIR/polepole-dev-backup" "$SUPPORT"
```

期待: `/tmp/polepole-poc.log` に `[ERROR] プロジェクトのパスが見つかりません: /tmp/nonexistent-project-p14` が出て、それ以降 `workspace` / `WorkspaceModel` 関連の行が出ない（= `setActive` が `workspace(for:)` を呼ぶ前に return している）。クラッシュもしない。

### 14. アトミック書き込み・バックアップ世代（手動）

実機で確認:
- ピン留めを 4 回切り替える
- `ls "$HOME/Library/Application Support/polepole-dev/"` で `projects.json` `.1` `.2` `.3` が並ぶ
- ピン留め中に強制終了させても `projects.json` か `.1` が読み取れること

### 15. 「再選択」メニュー（手動）

実機で確認:
- missing 状態の行を右クリック → 「再選択…」が出る
- 選ぶと NSOpenPanel が開く
- 別のフォルダを選ぶと displayName とアイコンが復活する
- アプリを再起動してもパスが永続化されている

### 16. プロジェクトごとのターミナル + cwd（自動）

`POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` で起動時に N 番目のピン留めを active にできる（デバッグ用フラグ。本番では使わない）。

```bash
pkill -x "PolePole Dev" 2>/dev/null
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"Documents","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/Users/d0ne1s/Documents"}
  ],
  "schemaVersion" : 1
}
JSON
APP=/tmp/polepole-build/Build/Products/Debug/ide.app

# index=0 で ide を active 起動 → cwd が /Users/d0ne1s/ide のターミナル
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 2
./scripts/polepole-screenshot.sh /tmp/v-step4-ide-term.png
grep "surface\] new" /tmp/polepole-poc.log | tail -2
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4

# index=1 で Documents を active 起動 → cwd が /Users/d0ne1s/Documents のターミナル
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=1 "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 2
./scripts/polepole-screenshot.sh /tmp/v-step4-documents.png
grep "surface\] new" /tmp/polepole-poc.log | tail -2
```

期待:
- ide active 時のスクショで右ペインのプロンプトに `~/ide main !` が出る（cwd が /Users/d0ne1s/ide）
- Documents active 時のスクショでプロンプトに `~/Documents` が出る
- ログに `[surface] new ok cwd=...` が project に応じて変わる
- 中央ペインに active project の名前とパスが表示される

クリーンアップ:
```bash
pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

### 17. プロジェクト切替の状態保持（手動）

実機で確認（要件「ターミナルセッションは生きっぱなし」）:
- ide active のターミナルで `echo from-ide` を実行
- 左サイドバーで Documents をクリック → ターミナル切替（cwd が変わる）
- もう一度 ide をクリック → 前の echo 出力が見える、新しい login 行は出ない
- ide のターミナルで `claude` を起動して回しっぱなしにする → Documents に切り替えても claude は動き続ける（プロセス的に kill されない）

### 18. Ctrl+M MRU 切替オーバーレイ（自動）

要件: TUI（vim/claude）内でも例外なく PolePole が捕捉。逃がし手段はなし。

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"Documents","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/Users/d0ne1s/Documents"}
  ],
  "schemaVersion" : 1
}
JSON
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/tmp/polepole-stdout.log 2>&1 &
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
./scripts/polepole-screenshot.sh /tmp/v-step5-overlay.png
osascript -e 'tell application "System Events" to key up control'
sleep 0.4
./scripts/polepole-screenshot.sh /tmp/v-step5-after-commit.png
```

期待:
- overlay スクショで中央に半透明パネル、ide / Documents の 2 件が並び、Documents（直前=MRU 2 番目）が青ハイライト
- after-commit スクショで Documents が active（左サイドバーで青ハイライト、右ペインの cwd が `~/Documents`）

#### 18-B. vim 起動中に Ctrl+M

```bash
./scripts/polepole-keystroke.sh --enter "vim README.md"
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
./scripts/polepole-screenshot.sh /tmp/v-step5-vim-overlay.png
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
./scripts/polepole-screenshot.sh /tmp/v-step5-after-esc.png
```

期待: Documents が active のまま（Esc で active 不変、MRU も不変）。

クリーンアップ:
```bash
pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

### 19. Ctrl+M 連打サイクル（手動）

実機で確認:
- 3 つ以上のプロジェクトを開いて MRU を貯める（A → B → C と順に active 化）
- A active の状態で **Ctrl 押しっぱなしで M 連打**
  - 1 回目: B にカーソル（直前）
  - 2 回目: C にカーソル
  - 3 回目: A にカーソル（一周）
- Ctrl 離した瞬間に確定 → 選んでた project が active になる

#### 19-A. 候補は直近 5 件まで（手動）

`mruCandidates()` は最大 5 件（`mruLimit`）で打ち切る。並び順は「このセッションで切り替えた順（MRU）」優先、残り枠は `lastOpenedAt` 降順。

6 件フィクスチャで起動:
```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"p1","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T06:00:00Z","path":"/Users/d0ne1s/ide"},
    {"displayName":"p2","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-09T05:00:00Z","path":"/Users/d0ne1s/Documents"},
    {"displayName":"p3","id":"33333333-3333-3333-3333-333333333333","isPinned":true,"lastOpenedAt":"2026-05-09T04:00:00Z","path":"/Users/d0ne1s/Downloads"},
    {"displayName":"p4","id":"44444444-4444-4444-4444-444444444444","isPinned":true,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"/Users/d0ne1s/Desktop"},
    {"displayName":"p5","id":"55555555-5555-5555-5555-555555555555","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/Users/d0ne1s/Public"},
    {"displayName":"p6","id":"66666666-6666-6666-6666-666666666666","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/Movies"}
  ],
  "schemaVersion" : 1
}
JSON
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/tmp/polepole-stdout.log 2>&1 &
sleep 2
```

Ctrl 押しっぱなしで M 連打 → overlay の候補が **5 件で止まる**こと（p6 は出ない。`lastOpenedAt` が一番古いため）。さらに p3 を一度 active 化してから Ctrl+M すると p3 が先頭に来て、代わりに末尾の 1 件が押し出されること。

クリーンアップ:
```bash
pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

### 20. ファイルツリー基本表示（自動）

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}
  ],
  "schemaVersion" : 1
}
JSON
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/tmp/polepole-stdout.log 2>&1 &
sleep 2.5
./scripts/polepole-screenshot.sh /tmp/v-step6-tree.png
```

期待:
- 中央ペインに ide リポジトリの直下子（フォルダ先・アルファベット順）が表示
  - .git / .refs / docs / GhosttyKit.xcframework / polepole.xcodeproj / Resources / scripts / Sources
  - .gitignore / .mise.toml / project.yml / REQUIREMENTS.md / VERIFY.md
- 各ディレクトリの左に展開 chevron（▶）
- 拡張子別アイコン: .md = 紫の doc.richtext、.toml/.yml = doc.text、folder = 青
- ツールバー: tree アイコン + プロジェクト名 + 👁 (gitignore 表示トグル) + 🔄 (reload)

クリーンアップ:
```bash
pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

### 21. ファイルツリー展開・右クリック（手動）

実機で確認（座標 click が SwiftUI の onTapGesture に届かないため自動不可）:
- ディレクトリの ▶ chevron か行をクリック → 子要素が展開（lazy scan で初回のみ僅かに遅延）
- もう一度クリックで折り畳み
- `.gitignore` 対象（例: `Sources/polepole/build` や `.refs/`）が薄表示になっている
- 👁 ボタンを押すと gitignore 対象が完全非表示になる、もう一度押すと薄表示に戻る
- 🔄 ボタンを押すと再スキャンされる（変更が反映される）
- 行を一度クリックしてツリーにフォーカスを当てた状態で **Cmd+R** を押しても再スキャンされる（端末ペインにフォーカスがあるときは無反応 = 端末側に素通る）
- ファイルを右クリック → 「相対パスをコピー」「ターミナルで開く」
  - 相対パスをコピー: pasteboard に project root からの相対パスが入る
  - ターミナルで開く: 暫定実装（pasteboard に `cd <絶対パス>\n` が入る、step8 以降で active terminal に直接送る予定）

### 22. シンボリックリンクの扱い（手動）

実機で確認:
- ディレクトリ symlink（例: `.refs/cmux` のような external clone）は中身を辿らず、矢印 → リンク先パスが表示される
- ファイル symlink は通常のファイルとして表示、矢印で target も併記

### 23. git status バッジ（自動）

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
echo "<!-- step7 test marker -->" >> /Users/d0ne1s/ide/VERIFY.md
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/tmp/polepole-stdout.log 2>&1 &
sleep 4
./scripts/polepole-screenshot.sh /tmp/v-step7-modified.png
pkill -x "PolePole Dev" 2>/dev/null
git -C /Users/d0ne1s/ide checkout -- VERIFY.md
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待: スクショで VERIFY.md の右端に青い `M` バッジが見える（modified ステータス、3 秒 polling で更新）。

### 24. ファイルツリー差分反映（手動 / Phase 2.5）

要件「fs watcher でツリー差分反映」は Phase 2.5 で導入予定。MVP では手動 reload で代替:
- ターミナルで新規ファイル `touch newfile.txt` を作成
- ツリーには即時反映されない（FSEvents 未統合）
- ツリー右上の 🔄 ボタンを押す（またはツリーにフォーカスを当てて Cmd+R）と再スキャンされて新規ファイルが現れる
- 新規ファイルなら `?` バッジが付く（次の git status polling サイクル後）

### 25. ファイルプレビュー（自動）

`POLEPOLE_TEST_AUTO_PREVIEW` 環境変数で起動時に project root からの相対パスを開ける。

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
BIN="$APP/Contents/MacOS/PolePole Dev"

# Markdown（README.md は画像 ./docs/images/overview.png を埋め込んでいる）
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="README.md" "$BIN" >/dev/null 2>&1 &
sleep 3
./scripts/polepole-screenshot.sh /tmp/v-step8-md.png

# Swift コード
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="Sources/polepole/PolePoleApp.swift" "$BIN" >/dev/null 2>&1 &
sleep 3
./scripts/polepole-screenshot.sh /tmp/v-step8-swift.png

# XML (Info.plist)
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="Resources/Info.plist" "$BIN" >/dev/null 2>&1 &
sleep 3
./scripts/polepole-screenshot.sh /tmp/v-step8-plist.png
pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待:
- 中央ペインがプレビューモードに切替（ツールバー左に `folder` アイコン + `/` + ファイル名のパンくず、続いて履歴ナビ ← →、右端に「Cursor で開く」）
- Markdown はインラインレンダリング（リンク・強調が効く、見出しはプレーン）。`README.md` の `![]()` 画像（`docs/images/overview.png`）が壊れアイコンではなくちゃんと表示される（`ideres://` スキームハンドラ経由）
- コード（.swift）はモノスペースで表示
- XML はそのままプレーンテキスト
- パンくずのファイル名をクリック → 「相対パスをコピーしました: …」トースト + pasteboard に project root からの相対パスが入る（Markdown でも非 Markdown でも同じ。要手動: ホバーで下線が出てクリックできる）

### 25.5 プレビュー自動リロード（自動）

プレビュー中ファイルがディスク上で更新されたら、`FileChangeWatcher`（kqueue）が検知して
自動で classify し直す。エディタのアトミック保存（temp に書いて mv で差し替え）でも
delete/rename を検知して開き直すので追従が継続する。

```bash
BACKUP_DIR=$(mktemp -d)
cp -a "$HOME/Library/Application Support/polepole-dev" "$BACKUP_DIR/polepole-dev-backup" 2>/dev/null || true
mkdir -p /tmp/polepole-watchtest
printf '# Watch test\n\nVERSION ONE\n' > /tmp/polepole-watchtest/note.md
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"watchtest","id":"22222222-2222-2222-2222-222222222222","isPinned":true,"lastOpenedAt":"2026-05-11T00:00:00Z","path":"/tmp/polepole-watchtest"}],"schemaVersion":1}
JSON
: > /tmp/polepole-poc.log
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.6
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="note.md" "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 4
printf 'v2 in place\n' > /tmp/polepole-watchtest/note.md; sleep 1.5
printf 'v3 atomic\n' > /tmp/polepole-watchtest/note.md.new && mv /tmp/polepole-watchtest/note.md.new /tmp/polepole-watchtest/note.md; sleep 1.5
printf 'v4 atomic again\n' > /tmp/polepole-watchtest/note.md.new && mv /tmp/polepole-watchtest/note.md.new /tmp/polepole-watchtest/note.md; sleep 1.5
for i in 1 2 3 4 5; do printf "burst $i\n" >> /tmp/polepole-watchtest/note.md; done; sleep 1.5
grep -c "auto-reloaded" /tmp/polepole-poc.log
pkill -x "PolePole Dev" 2>/dev/null
rm -rf "$HOME/Library/Application Support/polepole-dev"
mv "$BACKUP_DIR/polepole-dev-backup" "$HOME/Library/Application Support/polepole-dev" 2>/dev/null || true
rm -rf /tmp/polepole-watchtest
```

期待:
- `/tmp/polepole-poc.log` に `[preview] auto-reloaded note.md` が **4 行**（v2 / v3 / v4 / burst×5 が 1 回にまとまる）。起動直後（編集前）には出ない
- 実機で見ると、編集のたびにプレビュー本文が新しい内容に切り替わる（スクロール位置はリセットされる — 既知）
- アクセシビリティ権限がない環境では screenshot が撮れないので、本文の目視は実機で確認する

### 26. プレビュー画像/PDF/バイナリ/大きいファイル（手動）

実機で確認:
- **画像**: ツリーから .png/.jpg などをクリック → ScrollView 内に画像が表示
- **PDF**: .pdf をクリック → PDFKit で表示、ページめくり可
- **バイナリ**: 実行可能ファイル等を選択 → 「バイナリファイルです（プレビュー非対応）」+「Cursor で開く」ボタン
- **5MB 〜 50MB（テキスト・画像・PDF いずれも）**: 「N MB のファイルです。読み込みますか？」確認 → 「読み込む」で実際の種別（テキスト / 画像 / PDF）として表示。サイズ判定は拡張子判定より前なので、巨大な画像/PDF もここで止まる
- **50MB 超**: 自動的に「外部で開いてください」+「Cursor で開く」
- **Cmd+Option+O**: Cursor が起動し、当該ファイルが開く
- **Esc / `folder` アイコンパンくず**: ツリーに戻る（ホバーで primary 色に変化）

### 26-a. プレビューのサイズしきい値（半自動・スクショ）

`POLEPOLE_TEST_AUTO_PREVIEW` で巨大ファイルを開いて確認 UI に分岐するかをスクショで確認する。
（`PolePole.app` に画面収録権限がある前提 — [docs/DEV.md の TCC の節](./docs/DEV.md#tccプライバシー権限の罠) 参照）

```bash
BACKUP_DIR=$(mktemp -d); cp -a "$HOME/Library/Application Support/polepole-dev" "$BACKUP_DIR/polepole-dev" 2>/dev/null || true
TD=/tmp/polepole-verify-proj; rm -rf "$TD"; mkdir -p "$TD"
# 6MB テキスト / 60MB テキスト / 6MB の非圧縮ノイズ PNG
yes "padding line padding line padding line padding line padding line" | head -c 6291456 > "$TD/big6mb.txt"
yes "padding line padding line padding line padding line padding line" | head -c 62914560 > "$TD/huge60mb.txt"
python3 -c "import zlib,struct,os;W=H=1500;raw=bytearray();r=os.urandom(W*H*3);i=0
for y in range(H):raw.append(0);raw.extend(r[i:i+W*3]);i+=W*3
def c(t,d):return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
p=b'\x89PNG\r\n\x1a\n'+c(b'IHDR',struct.pack('>IIBBBBB',W,H,8,2,0,0,0))+c(b'IDAT',zlib.compress(bytes(raw),1))+c(b'IEND',b'')
open('$TD/noise6mb.png','wb').write(p)"
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"schemaVersion":1,"projects":[{"id":"aaaaaaaa-0000-0000-0000-000000000001","path":"/tmp/polepole-verify-proj","displayName":"verify-proj","isPinned":true,"lastOpenedAt":"2026-05-12T00:00:00Z"}]}
JSON
rm -f "$HOME/Library/Application Support/polepole-dev"/projects.json.[0-9]
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
for f in big6mb.txt huge60mb.txt noise6mb.png; do
  pkill -x "PolePole Dev" 2>/dev/null; sleep 0.6
  POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="$f" "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
  sleep 4; ./scripts/polepole-screenshot.sh "/tmp/v26-$f.png"
done
pkill -x "PolePole Dev" 2>/dev/null
rm -rf "$HOME/Library/Application Support/polepole-dev"; mv "$BACKUP_DIR/polepole-dev" "$HOME/Library/Application Support/polepole-dev" 2>/dev/null || true
rm -rf "$TD"
```

期待（スクショで目視）:
- `big6mb.txt` / `noise6mb.png` → 中央ペインに「6.0 MB のファイルです。読み込みますか？」+「読み込む」「Cursor で開く」（**画像も拡張子判定より前にサイズで止まる**のがポイント）
- `huge60mb.txt` → 「ファイルサイズが大きいか UTF-8 でないため外部で開いてください」+「Cursor で開く」のみ
- ※「読み込む」を押した後に実際の種別で表示されるか・Markdown のプロジェクト外リンクのコピー挙動・overlay 上の Cmd+C は、クリック / キーストロークが要るので手動確認（PolePole 内 Claude Code からは osascript の補助アクセスが効かないため自動化不可）

### 26-b. プレビューのファイル内検索 Cmd+F（半自動・スクショ + 手動）

`POLEPOLE_TEST_PREVIEW_FIND` で「プレビューを開いた状態 + 検索バーに語を入れてハイライト済み」の状態で起動できる。

```bash
BACKUP_DIR=$(mktemp -d); cp -a "$HOME/Library/Application Support/polepole-dev" "$BACKUP_DIR/polepole-dev" 2>/dev/null || true
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
rm -f "$HOME/Library/Application Support/polepole-dev"/projects.json.[0-9]
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
# コード（hljs ハイライト下でも mark が乗るか）
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.6
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="Sources/polepole/ProjectsModel.swift" POLEPOLE_TEST_PREVIEW_FIND="preview" "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 5; ./scripts/polepole-screenshot.sh /tmp/v26b-code.png
# Markdown
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.6
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="REQUIREMENTS.md" POLEPOLE_TEST_PREVIEW_FIND="プレビュー" "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 5; ./scripts/polepole-screenshot.sh /tmp/v26b-md.png
pkill -x "PolePole Dev" 2>/dev/null
rm -rf "$HOME/Library/Application Support/polepole-dev"; mv "$BACKUP_DIR/polepole-dev" "$HOME/Library/Application Support/polepole-dev" 2>/dev/null || true
```

期待（スクショで目視）:
- プレビュー右上に検索バー（🔍 + 入力欄 + `現在/総数` + ↑↓ + ✕）が浮いている
- マッチが全部ハイライト（半透明イエロー）、現在のマッチだけオレンジ。最初のマッチが画面中央に来るようスクロールされている
- 検索語が 0 件のときは件数表示が赤の `0`（手動: 入力欄に適当な語を打って確認）

手動で確認（PolePole 内 Claude Code からは osascript の補助アクセスが効かず自動化不可）:
- プレビュー表示中に **Cmd+F** で検索バーが開き、入力欄にフォーカスが入る（ターミナル/WebView がフォーカスを握っていても奪える）。開いている状態でもう一度 Cmd+F で入力欄に再フォーカス
- 入力するたびにハイライトが更新される（120ms デバウンス）
- **Enter** / **Cmd+G** で次のマッチ、**Shift+Enter** / **Cmd+Shift+G** で前のマッチへ。↑↓ ボタンも同じ
- **Esc** で検索バーが閉じてハイライトが消える（プレビュー自体は閉じない）。もう一度 Esc でツリーに戻る
- 検索バーを開いたまま別ファイルへ（Cmd+P 等）移動しても、新しいファイルで同じ語が再ハイライトされる
- `Cmd+Shift+F`（全文検索）は従来どおり別物として動く

### 27. プレビュー履歴ナビ（手動）

実機で確認:
- ツリー → ファイル A をクリック → プレビュー A を表示、ツールバーの ← → は両方 disable
- ファイル B をクリック → プレビュー B、← が enable、→ は disable
- ← をクリック → A に戻る、→ が enable に
- → をクリック → B に進む
- 同じファイルを連続でクリックしても履歴は重複しない（A → A → B → A の操作で履歴は A → B → A の 3 件）

### 27.5 ツリー ↔ プレビュー トグル（Cmd+J / 自動）

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="CLAUDE.md" "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 3

# 起動直後: プレビュー表示中
./scripts/polepole-screenshot.sh /tmp/v-toggle-1.png

# Cmd+J でツリーへ
osascript -e 'tell application "System Events" to tell process "ide" to keystroke "j" using {command down}'
sleep 0.4
./scripts/polepole-screenshot.sh /tmp/v-toggle-2.png

# Cmd+J で再度プレビューへ（最後に見たファイル = CLAUDE.md）
osascript -e 'tell application "System Events" to tell process "ide" to keystroke "j" using {command down}'
sleep 0.4
./scripts/polepole-screenshot.sh /tmp/v-toggle-3.png

pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待:
- `v-toggle-1`: プレビュー（パンくず `📁 / CLAUDE.md`）
- `v-toggle-2`: ツリー表示。ヘッダ左の `doc.text` アイコンが secondary 色（履歴あり = enabled）
- `v-toggle-3`: 再びプレビュー、CLAUDE.md が復元

履歴ゼロ状態（一度もファイルを開いていない）では `doc.text` アイコンが tertiary 色 + disabled。Cmd+J を押しても無反応。

### 28. Cmd+P クイック検索（自動）

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
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
./scripts/polepole-screenshot.sh /tmp/v-step10-read.png
pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待: 中央上部にオーバーレイが表示され、検索結果の一番上に `REQUIREMENTS.md` が出る。

### 29. Cmd+P 操作（手動）

実機で確認:
- Cmd+P でオーバーレイ起動
- ↓↑ または Ctrl+N / Ctrl+P で選択を移動
- Enter で選んだファイルを preview に開く
- Esc でキャンセル
- スラッシュを含むクエリ（例: `sources/i`）はパスマッチに自動切替で精度が変わる

### 30. Cmd+Shift+F 全文検索（自動）

`POLEPOLE_TEST_AUTO_FULLSEARCH` で起動時に grep を実行できる。

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[{"displayName":"ide","id":"11111111-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/Users/d0ne1s/ide"}],"schemaVersion":1}
JSON
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_PREVIEW="REQUIREMENTS.md" POLEPOLE_TEST_AUTO_FULLSEARCH="Project" "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 4
./scripts/polepole-screenshot.sh /tmp/v-step11-search.png
pkill -x "PolePole Dev" 2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待: スクショで `Project` の検索結果が複数件並ぶ（VERIFY.md / phase2-files.md / MRUKeyMonitor.swift など）。各行にファイル名 + 行番号 + プレビュー。

### 31. Cmd+Shift+F 操作（手動）

実機で確認:
- Cmd+Shift+F でオーバーレイ起動
- 文字を入力して Enter で検索実行（AppleScript 経由では onSubmit が効かないので手動必須）
- ↑↓ または Ctrl+N / Ctrl+P で結果選択、Enter / クリックで preview 切替
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
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
mkdir -p "$HOME/Library/Application Support/polepole-dev" /tmp/polepole-dnd-test/{alpha,bravo,charlie,delta,echo}
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{
  "projects" : [
    {"displayName":"alpha","id":"AAAAAAAA-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/tmp/polepole-dnd-test/alpha"},
    {"displayName":"bravo","id":"BBBBBBBB-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/tmp/polepole-dnd-test/bravo"},
    {"displayName":"charlie","id":"CCCCCCCC-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"/tmp/polepole-dnd-test/charlie"},
    {"displayName":"delta","id":"DDDDDDDD-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T04:00:00Z","path":"/tmp/polepole-dnd-test/delta"},
    {"displayName":"echo","id":"EEEEEEEE-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T05:00:00Z","path":"/tmp/polepole-dnd-test/echo"}
  ],
  "schemaVersion" : 1
}
JSON
./scripts/polepole-launch.sh
sleep 0.8

# 座標は launch 後の osascript "position of front window" で取得した window 左上が (179, 154) のときのもの。
# alpha 中心 ≈ (249, 246)、echo 中心 ≈ (249, 371)、echo 下半分 ≈ (249, 385)
# alpha → echo 下半分にドラッグ = 自動で unpin、temp 末尾に移動
/tmp/simulate-drag 249 246 249 385
sleep 0.6
python3 -c "
import json
d = json.load(open('$HOME/Library/Application Support/polepole-dev/projects.json'))
for p in d['projects']: print(f\"  {p['displayName']}: pinned={p['isPinned']}\")
"

pkill -x "PolePole Dev" 2>/dev/null
rm -f /tmp/simulate-drag /tmp/simulate-drag.swift
rm -rf /tmp/polepole-dnd-test
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待出力:
```
  bravo: pinned=True
  charlie: pinned=False
  delta: pinned=False
  echo: pinned=False
  alpha: pinned=False
```

座標は実機のウィンドウ位置によって変わる。`./scripts/polepole-launch.sh` 後に AppleScript で取得した window 位置 + 行高さ 28pt を加算して計算する。

#### 32-C. setActive で MRU 並び替えしないことの確認（自動）

旧仕様では temporary を active 化すると先頭に移動していたが、ドラッグ並び替え導入で廃止した（手動順序を尊重）。

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev" /tmp/polepole-dnd-test/{a,b,c}
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[
  {"displayName":"a","id":"AAAAAAAA-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T01:00:00Z","path":"/tmp/polepole-dnd-test/a"},
  {"displayName":"b","id":"BBBBBBBB-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T02:00:00Z","path":"/tmp/polepole-dnd-test/b"},
  {"displayName":"c","id":"CCCCCCCC-1111-1111-1111-111111111111","isPinned":false,"lastOpenedAt":"2026-05-09T03:00:00Z","path":"/tmp/polepole-dnd-test/c"}
],"schemaVersion":1}
JSON
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
APP=/tmp/polepole-build/Build/Products/Debug/ide.app
# 末尾の c を active 化しても順序は a, b, c のまま（旧仕様だと c が先頭になる）
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=2 "$APP/Contents/MacOS/PolePole Dev" >/dev/null 2>&1 &
sleep 2
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
python3 -c "
import json
d = json.load(open('$HOME/Library/Application Support/polepole-dev/projects.json'))
print(','.join(p['displayName'] for p in d['projects']))
"
rm -rf /tmp/polepole-dnd-test
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待出力: `a,b,c`（c が先頭に移動していない）。

## 33. Diff overlay (Cmd+D)

中央ペイン上部の diff バッジが「変更あり=通常色+件数」「変更なし=薄め」で出し分けされ、Cmd+D / バッジクリックで overlay が開くことを確認する。

### 33-A. 差分あり状態のバッジ（自動）

ide リポジトリ自身を active にすれば、PolePole 内で変更ファイルがある状態を作りやすい（このセクションを実行する前提として、ide リポジトリに `git status` で見える変更が 1 件以上あること）。

```bash
mkdir -p "$HOME/Library/Application Support/polepole-dev"
cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<'JSON'
{"projects":[
  {"displayName":"ide","id":"AAAAAAAA-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-14T01:00:00Z","path":"/Users/d0ne1s/ide"}
],"schemaVersion":1}
JSON
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/tmp/polepole-launch.log 2>&1 &
sleep 5
./scripts/polepole-screenshot.sh /tmp/diff-badge-on.png
```

期待: スクショの中央ペイン右上に `±` 系アイコン + 件数 Capsule（青背景・白文字）が出ている。

### 33-B. overlay 表示（自動）

`POLEPOLE_TEST_AUTO_OPEN_DIFF=1` を加えて再起動すると、起動直後に overlay が開く。

```bash
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 POLEPOLE_TEST_AUTO_OPEN_DIFF=1 "$APP/Contents/MacOS/PolePole Dev" >/tmp/polepole-launch.log 2>&1 &
sleep 6
./scripts/polepole-screenshot.sh /tmp/diff-overlay.png
```

期待: ヘッダーに `Diff` `ide` `<件数> 件` `reload` `×` が並び、本体に各ファイルがサイドバイサイドで表示される（追加=緑、削除=赤、context=透明）。staged / unstaged バッジも色分けされる。

### 33-C. 差分なし状態のバッジ（自動）

clean な repo を一時的に作って active にする。

```bash
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
CLEAN_DIR=$(mktemp -d)
cd "$CLEAN_DIR" && git init -q && git config user.email "t@example.com" && git config user.name "t" && echo "clean" > README.md && git add . && git commit -q -m "init" && cd -

cat > "$HOME/Library/Application Support/polepole-dev/projects.json" <<JSON
{"projects":[
  {"displayName":"clean","id":"AAAAAAAA-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-05-14T01:00:00Z","path":"$CLEAN_DIR"}
],"schemaVersion":1}
JSON

POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 "$APP/Contents/MacOS/PolePole Dev" >/tmp/polepole-launch.log 2>&1 &
sleep 5
./scripts/polepole-screenshot.sh /tmp/diff-badge-empty.png

pkill -x "PolePole Dev" 2>/dev/null
rm -rf "$CLEAN_DIR"
rm -f "$HOME/Library/Application Support/polepole-dev/projects.json"*
```

期待: 中央ペイン右上のバッジが薄い色（secondary）で、件数 Capsule なし。

### 33-D. ショートカット動作（手動）

`ide-keystroke.sh` は PolePole 内 Claude Code からは動かないので、以下は実機 / 別ターミナルから確認する。

- ターミナル / ファイルツリーどちらにフォーカスがあっても `Cmd+D` で overlay が開く
- もう一度 `Cmd+D` を押すと閉じる（トグル）
- overlay 表示中の `Esc` で閉じる
- overlay 表示中の `Cmd+R` で `git diff` を取り直す（ヘッダーの reload アイコンと同じ挙動）
- バッジのクリックで overlay が開く
- ファイル名右の `±` アイコンで「ファイル全体表示 ↔ 差分のみ」がトグルできる

## 34. Sparkle "Check for Updates…"

メニュー > `PolePole Dev` > `Check for Updates…` で自前アップデートのチェックが走る。AppleScript でメニュー操作はできないので、メニュー目視と更新フローの完走確認は実機から行う。

### 34-A. Sparkle 統合（自動）

```bash
./scripts/polepole-launch.sh
sleep 3
pgrep -lf "PolePole Dev.app/Contents/MacOS/PolePole Dev" || echo "FAIL: not running"
# Info.plist の Sparkle キーが反映されていること
plutil -p "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/Info.plist" | grep -E "^\s*\"SU"
# Sparkle.framework が embed されていること（dylib + Updater.app + XPCServices）
ls "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/Frameworks/Sparkle.framework/Versions/B/" | grep -E "Sparkle|Updater.app|XPCServices"
```

期待:
- PolePole Dev プロセスが生存
- `SUFeedURL` = `https://github.com/nyshk97/polepole-releases/releases/latest/download/appcast.xml`
- `SUPublicEDKey` が空でない Base64 文字列
- `SUEnableAutomaticChecks` = false
- `Sparkle`（dylib）、`Updater.app`、`XPCServices` の 3 つが見える

### 34-B. メニュー表示（手動）

メニューバー > `PolePole Dev` を開き、`About PolePole Dev` の **直下** に `Check for Updates…` がある。`SUFeedURL` が設定済みなら enable（クリック可）。空文字なら disable（グレーアウト）。

### 34-C. release.sh のドライラン（自動）

実リリースを走らせる前に、`sign_update` と appcast 挿入ロジックだけ単体で確認できる:

```bash
# Sparkle ツール群が DerivedData にあること
ls /tmp/polepole-build/SourcePackages/artifacts/sparkle/Sparkle/bin/ | grep -E "generate_keys|sign_update"

# ダミー zip に EdDSA 署名を打って、edSignature と length が抽出できるか
cd /tmp && echo test > _t.txt && zip -q _t.zip _t.txt
SIG=$(/tmp/polepole-build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update _t.zip)
echo "$SIG" | grep -E 'sparkle:edSignature="[^"]+"' && echo "PASS"
rm -f _t.txt _t.zip
cd -
```

### 34-D. 古いバージョンが新版を検出する（手動・本番リリース後）

実リリースを 1 本通したあとに以下を実機で確認:

1. 現状の `/Applications/PolePole.app` を退避: `mv /Applications/PolePole.app /Applications/PolePole.app.bak`
2. 旧バージョン（例: `1.0.9`）の zip を `gh release download v1.0.9 --repo nyshk97/ide -p 'ide.zip' -O /tmp/old-ide.zip` で取得し `/Applications/` に展開
3. `/Applications/PolePole.app` を起動 → メニュー > `PolePole` > `Check for Updates…`
4. 「新版 X.X.X が利用可能」ダイアログ → `Install Update` → ダウンロード → 自動再起動
5. 起動した PolePole.app の `About` を見て新版になっていることを確認

退避したバックアップを戻すなら: `rm -rf /Applications/PolePole.app && mv /Applications/PolePole.app.bak /Applications/PolePole.app`

## 35. トライアル / ライセンス (Phase 5)

### 35-A. 通常起動でトライアル中の表示（自動）

```bash
mise run build
# clean state から始めたい場合だけ既存 trial を消す
rm -f "$HOME/Library/Application Support/polepole-dev/trial.json"
security delete-generic-password -s "local.d0ne1s.polepole.dev" -a "trial-install-date" 2>/dev/null
./scripts/polepole-launch.sh 4
./scripts/polepole-screenshot.sh /tmp/v-trial-normal.png
grep license /tmp/polepole-poc.log | tail -5
```

期待:
- ログに `[license] state = trial(14 days left)` が出る
- スクリーンショットは通常の 3 カラム表示で、Paywall は出ていない
- `~/Library/Application Support/polepole-dev/trial.json` と Keychain (Service `local.d0ne1s.polepole.dev` / Account `trial-install-date`) の両方に同じ ISO8601 タイムスタンプが書かれている

```bash
cat "$HOME/Library/Application Support/polepole-dev/trial.json"
security find-generic-password -s "local.d0ne1s.polepole.dev" -a "trial-install-date" -w
```

### 35-B. install date の二重保存と min による復元（自動）

```bash
# 状態: 35-A 実行直後 (trial.json + Keychain に同じ install date)
pkill -x "PolePole Dev" || true
sleep 0.5
rm -f "$HOME/Library/Application Support/polepole-dev/trial.json"
./scripts/polepole-launch.sh 3
cat "$HOME/Library/Application Support/polepole-dev/trial.json"
# → Keychain の値が trial.json に復元されている

pkill -x "PolePole Dev" || true
sleep 0.5
security delete-generic-password -s "local.d0ne1s.polepole.dev" -a "trial-install-date"
./scripts/polepole-launch.sh 3
security find-generic-password -s "local.d0ne1s.polepole.dev" -a "trial-install-date" -w
# → trial.json の値が Keychain に復元されている
```

期待: どちらの方向でも install date が保存され、initial timestamp が変わらない (= 残日数が不変)。

### 35-C. POLEPOLE_TEST_LICENSE_FAKE_NOW で期限切れ画面（自動）

```bash
# 状態: 35-A 実行後で trial.json か Keychain に install date が入っている
INSTALL_ISO=$(cat "$HOME/Library/Application Support/polepole-dev/trial.json" | grep installDate | sed 's/.*"\([0-9TZ:-]*\)".*/\1/')
INSTALL_UNIX=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$INSTALL_ISO" "+%s")
FAKE_NOW=$((INSTALL_UNIX + 15*86400))   # 15 日経過

pkill -x "PolePole Dev" || true
sleep 0.5
launchctl setenv POLEPOLE_TEST_LICENSE_FAKE_NOW "$FAKE_NOW"
open -n "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
sleep 4
launchctl unsetenv POLEPOLE_TEST_LICENSE_FAKE_NOW
./scripts/polepole-screenshot.sh /tmp/v-paywall.png
grep license /tmp/polepole-poc.log | tail -3
```

期待:
- ログに `[license] state = trialExpired` が出る
- スクリーンショットに「トライアル期間が終了しました」見出し / 「¥11,800 Lifetime License」 / 「購入する」ボタン / メアド+キー入力フォーム / 「お問い合わせ」リンクが映る
- 背景の 3 カラムは暗く覆われていて、Paywall モーダルが前面に来ている

### 35-D. Settings の License タブ表示（手動）

`Cmd+,` で Settings ウィンドウを開く → 上部に「Shortcuts」「License」の 2 タブが見える → 「License」をクリック。

期待: ライセンスタブで「トライアル中 (残り N 日)」のステータス + メアド/キー入力フォーム + 「アクティベート」ボタン (現状は LicenseStore が stub なので押しても何も起きない、Phase 6 で実装) + 「購入ページを開く」リンクが見える。

