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

### 4レイアウトのスクリーンショット確認

```bash
# split（上下2分割、デフォルト）
osascript -e 'tell application "System Events" to key code 19 using {command down, option down}'
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-split.png

# splitHorizontal（左右2分割）
osascript -e 'tell application "System Events" to key code 20 using {command down, option down}'
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-splitH.png

# splitFour（2×2グリッド）
osascript -e 'tell application "System Events" to key code 21 using {command down, option down}'
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-split4.png

# singleBottom（1ペイン）
osascript -e 'tell application "System Events" to key code 18 using {command down, option down}'
sleep 0.5
./scripts/polepole-screenshot.sh /tmp/v-single.png
```

- `v-split.png`: 水平 divider で上下2段
- `v-splitH.png`: 垂直 divider で左右2列
- `v-split4.png`: 外側水平 + 左右各垂直の 2×2 グリッド（4ペイン）
- `v-single.png`: 下ペインのみ（上が collapsed）

### ペイン共通の動作（手動）

- 起動直後は **下ペインがアクティブ**（カーソルが塗りつぶし、上は中空）
- 分割境界をドラッグして幅/高さを変えられる
- 上ペインをクリック → 上ペインがアクティブになる
- 各ペインで `Cmd+T` → そのペインのタブだけ追加される
- `Cmd+Opt+↑/↓`: topPane / bottomPane 間フォーカス移動（split/splitHorizontal）

各ペインは独立した PTY:
```bash
./scripts/polepole-keystroke.sh --enter "tty"
```
を上下（または左右）それぞれで打って異なる TTY が出ることを確認。

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
- 選択後メニューバーの `Edit > Copy` でもクリップボードへコピーされる（外部アプリの AXPress Copy 経路も同じ action を使う）
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

### 21.5. ProcessRunner 劣化状態・ツリー ignore 後追い反映（自動）

`.gitignore` の薄表示はツリー表示後にバックグラウンドで**後追い反映**される（メインスレッドを git にブロックさせない設計。2026-07 のフリーズ根治）。リロード直後の一瞬だけ薄表示が付いていないのは仕様。

ProcessRunner（外部コマンド実行基盤）と FileTreeModel の回帰はユニットテストで確認する:

```bash
# EOF 不達 pipe の連発でもスレッド/ハンドラをリークしないこと、
# stdin の EPIPE/SIGPIPE 安全性、ignore 後追い反映の世代破棄まで含む
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project polepole.xcodeproj -scheme polepole -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/polepole-build test \
  -only-testing:polepoleTests/ProcessRunnerTests \
  -only-testing:polepoleTests/FileTreeModelTests 2>&1 |
  grep -E "Test Case.*(passed|failed)|Executed"
```

期待: 全テスト passed（スイート全体で 10 秒以内）。

加えて実機ログで劣化状態が起きていないことを確認できる:

```bash
# 0 件（またはレート制限付きのごく少数）であること。連発していたら EOF 不達が慢性化している
grep -c "drain timed out" /tmp/polepole-poc.log
```

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
- ツリーには即時反映されない（FSEvents は **Cmd+P インデックスにのみ** 統合済み、ツリーは未対応）
- ツリー右上の 🔄 ボタンを押す（またはツリーにフォーカスを当てて Cmd+R）と再スキャンされて新規ファイルが現れる
- 新規ファイルなら `?` バッジが付く（次の git status polling サイクル後）

### 24-bis. Cmd+P インデックスの FSEvents 自動更新（自動）

Cmd+P (`FileIndex`) は project root を FSEvents で再帰監視しており、ファイル作成・削除・リネームが
1〜3 秒以内に自動反映される。検証用の `POLEPOLE_TEST_AUTO_FSEVENTS_PROBE=<filename>` env で、
起動後に当該ファイル名を active project に作成 → 待機 → `FileIndex.search()` の結果を Logger
に出すまでを自動実行できる。

`open -n` は env を引き継がない経路があるので、binary 直叩きで起動する。

```bash
pkill -x "PolePole Dev" 2>/dev/null; sleep 0.4
rm -f /tmp/polepole-poc.log
BIN="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev"
PROBE_NAME="probe_$(date +%s).md"
POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 \
  POLEPOLE_TEST_AUTO_FSEVENTS_PROBE="$PROBE_NAME" \
  "$BIN" >/dev/null 2>&1 &
sleep 18
grep -E "fsevents-probe|rebuild" /tmp/polepole-poc.log
pkill -x "PolePole Dev" 2>/dev/null
```

期待:
- `[fsevents-probe] initial rebuild done entries=<N>` (起動直後)
- `[fsevents-probe] created <path>/<filename>`
- `[fsevents] rebuild start reason=fsevents` (touch から 2 秒以内)
- `[fsevents] rebuild end entries=<N+1>` (entries が増えている)
- `[fsevents-probe] search(<filename>) hits=1` ← **新規作成が反映**
- `[fsevents-probe] removed <path>/<filename>`
- `[fsevents] rebuild start reason=fsevents` (rm から)
- `[fsevents] rebuild end entries=<N>` (entries が元に戻る)
- `[fsevents-probe] after-delete search(<filename>) hits=0` ← **削除が反映**

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
- Markdown 内リンクは常時小さなアイコン付きで表示される。project root 配下の内部リンク（例: `./docs/DEV.md`）は `→`、外部リンク（例: `https://mise.jdx.dev/` や GitHub URL）は `⧉`
- Markdown 内のページ内アンカー（例: `#makefile`）は同一ドキュメント内の該当見出しへ移動できる
- コード（.swift）はモノスペースで表示
- XML はそのままプレーンテキスト
- パンくずのファイル名にホバー → 右に小さいコピーアイコン (`doc.on.doc`) が現れる（ホバーを外すと消える）。クリック → アイコンが ✓（緑）に 1 秒だけ切り替わり、pasteboard に project root からの相対パスが入る（Markdown でも非 Markdown でも同じ）。右下のトーストは出ない

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
- 実機で見ると、編集のたびにプレビュー本文が新しい内容に切り替わる。**同じファイルの再描画ではスクロール位置を保持する**（別ファイルへ切替えた場合のみ先頭に戻る）
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

検索バー用キー（Esc / Return / Cmd+G）を握る条件「first responder がプレビュー配下」の判定はユニットテストで確認する:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project polepole.xcodeproj -scheme polepole -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/polepole-build test \
  -only-testing:polepoleTests/PreviewFocusTests 2>&1 |
  grep -E "^Test Case .*(passed|failed)|Executed"
```

期待: 4 テスト passed（入力欄の field editor がフォーカス → 配下、ターミナル相当の NSView がフォーカス → 配下でない、など）。

手動で確認（PolePole 内 Claude Code からは osascript の補助アクセスが効かず自動化不可）:
- プレビュー表示中に **Cmd+F** で検索バーが開き、入力欄にフォーカスが入る（ターミナル/WebView がフォーカスを握っていても奪える）。開いている状態でもう一度 Cmd+F で入力欄に再フォーカス
- **検索バーを開いたままターミナルをクリック** → 端末で `echo hi` + **Enter** がそのまま実行される（次のマッチへ移らない）。**Esc** も端末に届く（vim / claude の Esc が効く。バーは閉じない）。**Cmd+G** も端末側に流れる。検索バーとハイライトは表示されたまま残り、**Cmd+F** で入力欄に戻れる
- 入力するたびにハイライトが更新される（120ms デバウンス）
- **Enter** / **Cmd+G** で次のマッチ、**Shift+Enter** / **Cmd+Shift+G** で前のマッチへ。↑↓ ボタンも同じ
- **Esc** で検索バーが閉じてハイライトが消える（プレビュー自体は閉じない）。もう一度 Esc でツリーに戻る
- 検索バーを開いたまま別ファイルへ（Cmd+P 等）移動しても、新しいファイルで同じ語が再ハイライトされる
- `Cmd+Shift+F`（全文検索）は従来どおり別物として動く

### 27. プレビュー履歴ナビ（手動）

履歴モデル: **時系列ログ**。`open()`（ツリー click / markdown リンク / Cmd+P / Cmd+Shift+F / ← / → ボタンで開いた場合を除く各種経路）の呼び出しだけが履歴に積まれる。← / → は履歴を変えず index を動かすだけ。連続同一ファイルだけ重複を回避する。**forward 履歴は truncate されない**。

#### 27.1 基本操作

実機で確認:
- ツリー → ファイル A をクリック → プレビュー A を表示、ツールバーの ← → は両方 disable
- ファイル B をクリック → プレビュー B、← が enable、→ は disable
- ← をクリック → A に戻る、→ が enable に
- → をクリック → B に進む
- 同じファイルを連続でクリックしても履歴は重複しない（A → A → B → A の操作で履歴は A → B → A の 3 件）

#### 27.2 forward 履歴の保持（時系列ログ）

過去に ← で戻った状態から別ファイルを開いても forward が消えないこと:

1. ファイル A をクリック → preview A
2. close（フォルダアイコンか Esc）
3. ファイル B をクリック → preview B
4. ← → preview A
5. close
6. ファイル C をクリック → preview C
7. ← → **preview B**（旧実装ではここで preview A に飛んでいた）
8. ← → preview A
9. → → preview B → → → preview C

履歴は `[A, B, C]`、現在 index は 0 → 1 → 2 と移動する。`B` が `C` を開いた瞬間に消えないのが時系列ログのキモ。

#### 27.3 ツリーのハイライトが追従する

preview の現在ファイルがツリー上で薄く強調されることを以下の経路で確認:

- 通常のツリー click 後
- ← / → ボタンで navigation した後
- markdown 内のローカルリンクで遷移した後
- Cmd+P (recents) で開いた後
- Cmd+Shift+F（全文検索）の hit jump 後

close（プレビューペインを折り畳む）してもハイライトは消えない（直前に見ていたファイルを示すため残す）。

**注意**: 未展開ディレクトリ配下のファイルを開いた場合、ツリーに行自体が無いためハイライトは見えない（selection は設定されているが render されない）。親ディレクトリを手で展開すると該当行が highlighted な状態で出てくる。自動 reveal は未実装（別 issue）。

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

## 34. Nested repo の Cmd+P / Cmd+Shift+F / Diff（自動）

active project root の直下に child repository があり、親 `.gitignore` が child repository directory を ignore している fixture で確認する。Debug 版の `polepole-dev/projects.json` を一時的に差し替えるので、既存データは退避して最後に復元する。

```bash
APP="/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
WORKSPACE=$(mktemp -d /tmp/polepole-nested-verify.XXXXXX)
BACKUP_DIR=$(mktemp -d /tmp/polepole-dev-backup.XXXXXX)
APP_SUPPORT="$HOME/Library/Application Support/polepole-dev"
ROOT="$WORKSPACE/root"
CHILD="$ROOT/child-repo"
ROOT_ONLY="$WORKSPACE/root-only"

cleanup() {
  pkill -x "PolePole Dev" 2>/dev/null || true
  pkill -f "PolePole Dev.app/Contents/MacOS/PolePole Dev" 2>/dev/null || true
  if [ -d "$BACKUP_DIR/polepole-dev" ]; then
    rm -rf "$APP_SUPPORT" 2>/dev/null || true
    mv "$BACKUP_DIR/polepole-dev" "$APP_SUPPORT"
  else
    rm -f "$APP_SUPPORT/projects.json" "$APP_SUPPORT/projects.json.tmp" 2>/dev/null || true
  fi
  rm -rf "$WORKSPACE" "$BACKUP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$ROOT" "$CHILD" "$ROOT_ONLY"
git -C "$ROOT" init -q
git -C "$ROOT" config user.email "verify@example.com"
git -C "$ROOT" config user.name "Verify"
printf 'child-repo\n' > "$ROOT/.gitignore"
printf 'needle-root\n' > "$ROOT/root.txt"

git -C "$CHILD" init -q
git -C "$CHILD" config user.email "verify@example.com"
git -C "$CHILD" config user.name "Verify"
printf '*.ignored\n' > "$CHILD/.gitignore"
printf 'needle-child\n' > "$CHILD/visible.txt"
printf 'needle-hidden\n' > "$CHILD/hidden.ignored"

git -C "$ROOT_ONLY" init -q
git -C "$ROOT_ONLY" config user.email "verify@example.com"
git -C "$ROOT_ONLY" config user.name "Verify"
printf 'root-only\n' > "$ROOT_ONLY/root-only.txt"

if [ -d "$APP_SUPPORT" ]; then cp -a "$APP_SUPPORT" "$BACKUP_DIR/polepole-dev"; fi
mkdir -p "$APP_SUPPORT"
cat > "$APP_SUPPORT/projects.json" <<JSON
{"projects":[{"displayName":"nested-verify","id":"AAAAAAAA-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-06-16T01:00:00Z","path":"$ROOT"}],"schemaVersion":1}
JSON

pkill -x "PolePole Dev" 2>/dev/null || true
open -n "$APP" --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 --env POLEPOLE_TEST_AUTO_QUICKSEARCH=visible
sleep 5
./scripts/polepole-screenshot.sh /tmp/nested-quick.png

pkill -x "PolePole Dev" 2>/dev/null || true
open -n "$APP" --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 --env POLEPOLE_TEST_AUTO_FULLSEARCH=needle-child
sleep 6
./scripts/polepole-screenshot.sh /tmp/nested-fullsearch.png

pkill -x "PolePole Dev" 2>/dev/null || true
open -n "$APP" --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0
sleep 5
./scripts/polepole-screenshot.sh /tmp/nested-badge-plus.png

pkill -x "PolePole Dev" 2>/dev/null || true
open -n "$APP" --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0 --env POLEPOLE_TEST_AUTO_OPEN_DIFF=1
sleep 6
./scripts/polepole-screenshot.sh /tmp/nested-diff-overlay.png

cat > "$APP_SUPPORT/projects.json" <<JSON
{"projects":[{"displayName":"root-only","id":"BBBBBBBB-1111-1111-1111-111111111111","isPinned":true,"lastOpenedAt":"2026-06-16T01:00:00Z","path":"$ROOT_ONLY"}],"schemaVersion":1}
JSON
pkill -x "PolePole Dev" 2>/dev/null || true
open -n "$APP" --env POLEPOLE_TEST_AUTO_ACTIVATE_INDEX=0
sleep 5
./scripts/polepole-screenshot.sh /tmp/root-only-badge.png
```

期待:
- `/tmp/nested-quick.png`: Cmd+P に `child-repo/visible.txt` が出る
- `/tmp/nested-fullsearch.png`: Cmd+Shift+F に `needle-child` の 1 hit が出る
- `/tmp/nested-badge-plus.png`: child repository に変更があるため diff badge が `+` capsule になる
- `/tmp/nested-diff-overlay.png`: diff overlay が root `.` と `child-repo` のタブに分かれ、選択中タブの差分だけが表示される
- `/tmp/root-only-badge.png`: root repository だけに変更があるため diff badge が数字表示になる
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

期待: ライセンスタブで「トライアル中 (残り N 日)」のステータス + メアド/キー入力フォーム + 「アクティベート」ボタン + 「購入ページを開く」リンクが見える。

### 35-E. Backend + アプリ アクティベーション E2E（半自動）

事前準備:
```bash
# backend を local D1 で起動
cd backend && pnpm dev &
sleep 4
curl -s http://127.0.0.1:8787/healthz   # → {"ok":true,...}

# D1 にテスト license を seed (キーは [A-Z2-9] 形式、0/1/I/L/O は不可)
TEST_KEY="polepole-TEST-ABCD-EFGH-JKMN"
pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "DELETE FROM device WHERE license_id = '$TEST_KEY'; DELETE FROM license WHERE id = '$TEST_KEY'; INSERT INTO license (id, email, stripe_session_id, stripe_payment_intent_id, amount, currency, status, created_at, updated_at, email_sent_at) VALUES ('$TEST_KEY', 'test@example.com', 'cs_test_e2e', 'pi_test_e2e', 11800, 'jpy', 'active', $(date +%s), $(date +%s), $(date +%s));"
```

アクティベート (curl 経由 — UI からの activate は手動目視 = 35-D で確認):
```bash
# このマシンの実 device_hash (= SHA256(IOPlatformUUID)) を取る
REAL_DEVICE_HASH=$(/usr/bin/swift - <<'SWIFT'
import IOKit; import CryptoKit; import Foundation
let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
let cf = IORegistryEntryCreateCFProperty(s, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
IOObjectRelease(s)
let uuid = (cf?.takeRetainedValue() as? String) ?? ""
let h = SHA256.hash(data: Data(uuid.utf8))
print(h.map { String(format: "%02x", $0) }.joined())
SWIFT
)
RESPONSE=$(curl -s -X POST http://127.0.0.1:8787/v1/license/activate \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"$TEST_KEY\",\"email\":\"test@example.com\",\"device_hash\":\"$REAL_DEVICE_HASH\",\"device_name\":\"polepole-dev-test\",\"os_version\":\"macOS test\",\"app_version\":\"1.0.0\"}")
echo "$RESPONSE" | python3 -m json.tool   # → status:ok, token:..., device:{...}
TOKEN=$(echo "$RESPONSE" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
mkdir -p "$HOME/Library/Application Support/polepole-dev"
python3 -c "import json; print(json.dumps({'token':'$TOKEN'}))" > "$HOME/Library/Application Support/polepole-dev/token.json"
```

⚠️ **Keychain には直接書かない**: `security add-generic-password` で書き込んだ item は、その後アプリから `SecItemCopyMatching` した時に「アプリにアクセス許可するか」のダイアログが裏で出て、可視化されずに init を block する事故が起きやすい。token.json にだけ書けば、アプリの初回 load() で fallback として読み込まれ、その後アプリが自分で Keychain にも書き戻す。

アプリ起動 & 検証:
```bash
pkill -9 -f "PolePole Dev" || true
sleep 1
# direct exec + env で起動 (open -n / launchctl setenv は前項の Keychain ダイアログ hang
# 問題に当たることがあるため、env を子プロセスに渡したいときは direct exec が確実)
POLEPOLE_BACKEND_URL="http://127.0.0.1:8787" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 4
grep license "$HOME/Library/Logs/polepole-dev/polepole-dev-$(date -u +%Y-%m-%d).log" | tail -5
```

期待: ログに `[license] state = activated (expires in 30 days)`。Keychain の `activation-token` も自動で書かれている (= 補完書きが効いている)。
```bash
security find-generic-password -s "local.d0ne1s.polepole.dev" -a "activation-token" -w | head -c 80
```

`./scripts/polepole-screenshot.sh /tmp/v-activated.png` で PaywallView が出ていない = 通常の 3 カラム表示。

### 35-F. Grace 切れ (issued_at + 31日) で deactivated（自動）

```bash
TOKEN=$(cat "$HOME/Library/Application Support/polepole-dev/token.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
ISSUED_AT=$(echo "$TOKEN" | cut -d. -f1 | python3 -c '
import sys,base64,json
b = sys.stdin.read().replace("-","+").replace("_","/")
b += "=" * ((4 - len(b) % 4) % 4)
print(json.loads(base64.b64decode(b))["issued_at"])
')
FAKE_NOW=$((ISSUED_AT + 31*86400))

pkill -9 -f "PolePole Dev" || true
sleep 1
POLEPOLE_TEST_LICENSE_FAKE_NOW=$FAKE_NOW POLEPOLE_BACKEND_URL="http://127.0.0.1:8787" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 4
grep license "$HOME/Library/Logs/polepole-dev/polepole-dev-$(date -u +%Y-%m-%d).log" | tail -3
./scripts/polepole-screenshot.sh /tmp/v-deactivated.png
```

期待:
- ログに `[license] token expired (issued_at + 30d < now), -> deactivated`
- スクリーンショットに「ライセンスが無効化されました / 30 日以上オンライン検証ができなかったため、ロックされました」見出し
- 背景の 3 カラムは暗く覆われていて、Paywall モーダルが前面 (Phase 5 の 35-C と同じレイアウト、ヘッドラインだけが違う)

### 35-G. デバイス上限超過 → スワップ UI（手動）

実マシンが 1 台しかない検証環境では sheet を出すのが難しいので、curl で 3 台分の架空デバイスを seed して、4 台目アクティベートで `device_limit` レスポンスが返ることだけ確認:

```bash
TEST_KEY="polepole-TEST-ABCD-EFGH-JKMN"
for i in 1 2 3; do
  HASH=$(printf "deadbeef%56s" "device$i" | tr ' ' '0')
  curl -s -X POST http://127.0.0.1:8787/v1/license/activate \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$TEST_KEY\",\"email\":\"test@example.com\",\"device_hash\":\"$HASH\",\"device_name\":\"fake-dev-$i\",\"app_version\":\"1.0.0\"}" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("status"), r.get("device", {}).get("id", r.get("error")))'
done
# 4 台目 (本物の device hash) で device_limit が返る
REAL_DEVICE_HASH=$(...)  # 35-E と同じ手順で取得
curl -s -X POST http://127.0.0.1:8787/v1/license/activate -H "Content-Type: application/json" \
  -d "{\"key\":\"$TEST_KEY\",\"email\":\"test@example.com\",\"device_hash\":\"$REAL_DEVICE_HASH\",\"device_name\":\"4th\",\"app_version\":\"1.0.0\"}" | python3 -m json.tool
```

期待: 最後の呼び出しが HTTP 409 で `{"error":"device_limit","existing_devices":[{...}, {...}, {...}]}` を返す。UI からの sheet 表示・スワップ動作は手動で確認 (アプリの「アクティベート」ボタン押下 → DeviceSwapSheet が開いて 3 台が一覧表示 → 1 台選んで「選択したデバイスを外して、このマシンを追加」)。

### 35-H. 残日数 7 日以下で menu bar 警告アイコン (Phase 7 / 半自動)

```bash
mise run build
INSTALL_UNIX=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" \
  "$(cat "$HOME/Library/Application Support/polepole-dev/trial.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["installDate"])')" "+%s")
FAKE_5=$((INSTALL_UNIX + 9*86400))   # 残 5 日
FAKE_2=$((INSTALL_UNIX + 12*86400))  # 残 2 日

# 残 5 日: menu bar に三角アイコン (オレンジ) 単体
pkill -9 -f "PolePole Dev" || true
sleep 1
POLEPOLE_TEST_LICENSE_FAKE_NOW=$FAKE_5 \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 4
screencapture -x -R 0,0,2880,40 /tmp/v-menubar-5days.png

# 残 2 日: menu bar に三角アイコン + "2" 数字併記 + 起動時トースト
pkill -9 -f "PolePole Dev" || true
sleep 1
POLEPOLE_TEST_LICENSE_FAKE_NOW=$FAKE_2 \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 4
screencapture -x -R 0,0,2880,40 /tmp/v-menubar-2days.png
./scripts/polepole-screenshot.sh /tmp/v-toast-2days.png
```

期待:
- `v-menubar-5days.png` の menu bar 右側に `exclamationmark.triangle.fill` のオレンジアイコン (数字なし)
- `v-menubar-2days.png` に同アイコン + ` 2` 数字併記
- `v-toast-2days.png` の画面右下に「PolePole のトライアルは残り 2 日です。」warning 色トースト
- 残日数 8 日以上 / trialExpired / activated ではアイコン非表示 (PaywallView と二重表示しないため)

### 35-I. verify 失敗時の grace 残り toast (Phase 7 / 手動)

```bash
# backend を停止した状態で activated → verify を強制的に走らせる
# 1) 35-E のステップで通常 activate 済み (token.json に有効 token がある)
# 2) backend を止める
pkill -f "wrangler dev" || true
sleep 1

# 3) verify は issued_at から 7 日経過したら走る。テスト時は token を手で作り変える
#    のが面倒なので、`POLEPOLE_TEST_LICENSE_FAKE_NOW` で issued_at + 8 日 にセット
TOKEN=$(python3 -c 'import json;print(json.load(open("'"$HOME"'/Library/Application Support/polepole-dev/token.json"))["token"])')
ISSUED_AT=$(echo "$TOKEN" | cut -d. -f1 | python3 -c '
import sys,base64,json
b = sys.stdin.read().replace("-","+").replace("_","/")
b += "=" * ((4 - len(b) % 4) % 4)
print(json.loads(base64.b64decode(b))["issued_at"])
')
FAKE_NOW=$((ISSUED_AT + 8*86400))

pkill -9 -f "PolePole Dev" || true
sleep 1
POLEPOLE_TEST_LICENSE_FAKE_NOW=$FAKE_NOW POLEPOLE_BACKEND_URL="http://127.0.0.1:8787" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 5  # verify が走るのを待つ (起動後すぐ ContentView.onAppear で verifyIfNeeded)
./scripts/polepole-screenshot.sh /tmp/v-grace-toast.png
grep "verify" "$HOME/Library/Logs/polepole-dev/polepole-dev-$(date -u +%Y-%m-%d).log" | tail -3
```

期待:
- ログに `[license] verify temp failed: network(message: ...)` (backend 停止のため connection refused)
- 画面右下に「ライセンスの再検証に失敗しました。あと NN 日でロックされます (ネットワーク要確認)」のトースト
- grace 残り 22 日 (issued_at から 8 日経過 = 残 22 日) なので `.info` 色 (青) で表示
- token は捨てられず、画面は `.activated` のまま (= 通常 3 カラム表示)

## 36. LP + 法的ページ (Phase 4)

### 36-A. Workers Assets + 動的ルート共存 (自動)

```bash
cd backend
pnpm typecheck                 # 0 エラー
pnpm test                      # 23 tests pass
pnpm dev >/tmp/wrangler-dev.log 2>&1 &
sleep 2

# static (assets)
curl -s -o /dev/null -w "GET / -> %{http_code} (%{size_download} bytes)\n"           http://localhost:8787/
curl -s -o /dev/null -w "GET /styles.css -> %{http_code} (%{size_download} bytes)\n" http://localhost:8787/styles.css
curl -sIL -o /dev/null -w "%{http_code} <- GET /legal/terms.html (after redirect)\n" http://localhost:8787/legal/terms.html
curl -s -o /dev/null -w "GET /legal/terms -> %{http_code}\n"                         http://localhost:8787/legal/terms
curl -s -o /dev/null -w "GET /legal/privacy -> %{http_code}\n"                       http://localhost:8787/legal/privacy
curl -s -o /dev/null -w "GET /legal/tokushoho -> %{http_code}\n"                     http://localhost:8787/legal/tokushoho

# 動的 (Worker)
curl -s -o /dev/null -w "GET /healthz -> %{http_code}\n"           http://localhost:8787/healthz
curl -s -o /dev/null -w "GET /thanks (no params) -> %{http_code}\n" http://localhost:8787/thanks

# 後片付け
pkill -f "wrangler dev" || true
```

期待:
- `/` → 200 で LP HTML が返る
- `/styles.css` → 200 で CSS が返る
- `/legal/*.html` → 307 で拡張子なしに正規化 → 200 (Workers Assets のデフォルト)
- `/healthz` → 200 / `/thanks` → 400 (Worker 側ハンドラが先に当たる、assets には流れない)
- `/nonexistent` → 404 (assets の 404 ページ)

### 36-B. LP の見栄え (手動)

```bash
cd backend && pnpm dev >/dev/null 2>&1 &
sleep 2
open -a Safari http://localhost:8787/
```

確認:
- ヘッドライン: 「Claude Code をストレスなく回す。」
- 価格セクション: ¥11,800 / Lifetime License / 14日トライアル / 3台アクティベート / 全 major version 無料アップデート
- ダウンロード: `brew install --cask nyshk97/tap/polepole` のコードブロック + DMG リンク
- フッター: 利用規約 / プライバシーポリシー / 特商法表記 / お問い合わせ
- システム設定の Light/Dark に追従して配色が切り替わる
- Stripe Payment Link / Zenn 記事 URL / スクショは launch 時に確定値に差し替える placeholder

### 36-C. 法的ページのドラフト確認 (手動)

```
http://localhost:8787/legal/terms
http://localhost:8787/legal/privacy
http://localhost:8787/legal/tokushoho
```

各ページ冒頭に「⚠️ 本ページはドラフトです。launch 前に確定版に差し替えます (Phase 8)。」の draft-notice が表示されること。terms は第 7 条「サービス終了時の救済」で 90 日前 universal token 配布を明記、privacy は Stripe / Resend / Cloudflare の第三者提供を明記。

## 37. メールテンプレ (Phase 8)

### 37-A. 単体テスト (自動)

```bash
cd backend
pnpm test test/email-templates.test.ts 2>&1 | tail
```

期待: `email-templates.test.ts (12 tests)` が全 pass。

- `buildLicenseKeyEmail`: from=`PolePole <support@polepole.dev>` / 件名に「ご購入ありがとうございます」「ライセンスキー」 / HTML+text に key と email が表示 / Lifetime License + サポート連絡先入り
- `buildLicenseResendEmail`: 件名に「再送」 / 「お心当たり / 破棄してください」の defense-in-depth 文言 / HTML+text に key と email
- `buildUniversalTokenEmail`: 件名に「サービス終了」「トークン」 / 引数の `licenseKey` / `universalToken` / `shutdownDate` がすべて HTML+text に注入 / 取り込み手順 (Settings → ライセンス)

### 37-B. /v1/license/resend 経由で新テンプレが選ばれる (半自動)

```bash
cd backend && pnpm dev >/tmp/wrangler-phase8.log 2>&1 &
sleep 4

# seed: テスト license が無ければ入れる
pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "INSERT OR IGNORE INTO license (id, email, stripe_session_id, stripe_payment_intent_id, amount, currency, status, created_at, updated_at, email_sent_at) VALUES ('polepole-TEST-ABCD-EFGH-JKMN', 'test@example.com', 'cs_test_seed', 'pi_test_seed', 11800, 'jpy', 'active', $(date +%s), $(date +%s), $(date +%s));"

# resend を叩く
curl -sS -X POST http://localhost:8787/v1/license/resend \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com"}'

# 新テンプレが noop モードで発火するか確認
grep "resend disabled" /tmp/wrangler-phase8.log | tail -3
pkill -f "wrangler" || true
```

期待:
- HTTP レスポンス: `{"status":"ok"}`
- ログに `[resend disabled] would send to=test@example.com subject="【PolePole】ライセンスキーの再送"` (購入直後の subject ではなく再送 subject が選ばれていることを確認)

## 38. Phase 9 E2E (AI 単独で完結する範囲)

35-E〜G 同等の手順だが、A-1 → A-2 → A-3 → A-4 を 1 セッションで通して通すための統合シナリオ。

### 38 共通: clean state にする

**重要**: 残骸 Keychain entry を消し忘れると `[license] keychain vs token.json mismatch, using keychain` で前テストの token が拾われ、`last-observed-now` の時計巻き戻し対策と相まって本来 valid な token も expired 扱いされる。Keychain 3 entry と Application Support 2 file をすべて消す:

```bash
pkill -9 -f "PolePole Dev" || true
pkill -f "wrangler" || true
sleep 1
security delete-generic-password -s "local.d0ne1s.polepole.dev" -a "trial-install-date" 2>/dev/null
security delete-generic-password -s "local.d0ne1s.polepole.dev" -a "activation-token"   2>/dev/null
security delete-generic-password -s "local.d0ne1s.polepole.dev" -a "last-observed-now"  2>/dev/null
rm -f "$HOME/Library/Application Support/polepole-dev/trial.json"
rm -f "$HOME/Library/Application Support/polepole-dev/token.json"
```

### 38-A. アプリ起動 E2E (D1 seed → activate → activated)

```bash
cd backend && pnpm dev >/tmp/wrangler-phase9.log 2>&1 &
sleep 4
curl -s http://localhost:8787/healthz

TEST_KEY="polepole-PHA9-TEST-EFGH-JKMN"
TEST_EMAIL="phase9@example.com"
pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "DELETE FROM device WHERE license_id = '$TEST_KEY'; DELETE FROM license WHERE id = '$TEST_KEY'; INSERT INTO license (id, email, stripe_session_id, stripe_payment_intent_id, amount, currency, status, created_at, updated_at, email_sent_at) VALUES ('$TEST_KEY', '$TEST_EMAIL', 'cs_phase9', 'pi_phase9', 11800, 'jpy', 'active', $(date +%s), $(date +%s), $(date +%s));"

REAL_DEVICE_HASH=$(/usr/bin/swift - <<'SWIFT'
import IOKit; import CryptoKit; import Foundation
let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
let cf = IORegistryEntryCreateCFProperty(s, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
IOObjectRelease(s)
let uuid = (cf?.takeRetainedValue() as? String) ?? ""
print(SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined())
SWIFT
)
RESPONSE=$(curl -s -X POST http://localhost:8787/v1/license/activate -H "Content-Type: application/json" \
  -d "{\"key\":\"$TEST_KEY\",\"email\":\"$TEST_EMAIL\",\"device_hash\":\"$REAL_DEVICE_HASH\",\"device_name\":\"polepole-phase9\",\"app_version\":\"1.0.0\"}")
TOKEN=$(echo "$RESPONSE" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
mkdir -p "$HOME/Library/Application Support/polepole-dev"
python3 -c "import json; print(json.dumps({'token':'$TOKEN'}))" > "$HOME/Library/Application Support/polepole-dev/token.json"
ISSUED_AT=$(echo "$TOKEN" | cut -d. -f1 | python3 -c 'import sys,base64,json;b=sys.stdin.read().replace("-","+").replace("_","/");b+="="*((4-len(b)%4)%4);print(json.loads(base64.b64decode(b))["issued_at"])')

POLEPOLE_BACKEND_URL="http://127.0.0.1:8787" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 4
grep "license" "$HOME/Library/Logs/polepole-dev/polepole-dev-$(date -u +%Y-%m-%d).log" | tail -2
./scripts/polepole-screenshot.sh /tmp/v-phase9-activated.png
```

期待: ログに `[license] state = activated (expires in 29 days)`、screenshot で Paywall 非表示の通常 3 カラム表示。

### 38-B. オフライン耐性 (verify 失敗 toast → grace 切れ deactivated)

```bash
# 38-A の続きで実行
pkill -9 -f "PolePole Dev" || true
pkill -f "wrangler" || true   # backend を止める = オフライン状態
sleep 2

# 8 日経過: verify が走るが backend 不在で network エラー → toast
FAKE_8D=$((ISSUED_AT + 8*86400))
POLEPOLE_TEST_LICENSE_FAKE_NOW=$FAKE_8D POLEPOLE_BACKEND_URL="http://127.0.0.1:8787" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 2   # toast は 4 秒で消えるので 2 秒で screenshot を撮る
./scripts/polepole-screenshot.sh /tmp/v-phase9-grace-toast.png
grep "verify temp failed" "$HOME/Library/Logs/polepole-dev/polepole-dev-$(date -u +%Y-%m-%d).log" | tail -1

# 31 日経過: token 期限切れで deactivated
pkill -9 -f "PolePole Dev" || true; sleep 1
FAKE_31D=$((ISSUED_AT + 31*86400))
POLEPOLE_TEST_LICENSE_FAKE_NOW=$FAKE_31D POLEPOLE_BACKEND_URL="http://127.0.0.1:8787" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 4
grep "token expired" "$HOME/Library/Logs/polepole-dev/polepole-dev-$(date -u +%Y-%m-%d).log" | tail -1
./scripts/polepole-screenshot.sh /tmp/v-phase9-deactivated.png
```

期待:
- 8 日経過: 画面右下に info 色 toast「ライセンスの再検証に失敗しました。あと 22 日でロックされます (ネットワーク要確認)」/ ログに `verify temp failed: network(...)`
- 31 日経過: ログに `token expired (issued_at + 30d < now), -> deactivated` / Paywall「ライセンスが無効化されました」表示

### 38-C. device_limit (4 台目で 409)

```bash
# 38-A の clean state + backend 起動済みから (38-B 後なら backend を再起動)
cd backend && pnpm dev >/tmp/wrangler-phase9.log 2>&1 &
sleep 4

TEST_KEY="polepole-PHA9-TEST-EFGH-JKMN"
TEST_EMAIL="phase9@example.com"
pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "DELETE FROM device WHERE license_id = '$TEST_KEY'; UPDATE license SET status='active' WHERE id='$TEST_KEY';"

for i in 1 2 3; do
  HASH=$(printf "deadbeef%56s" "device$i" | tr ' ' '0')
  curl -s -X POST http://localhost:8787/v1/license/activate -H "Content-Type: application/json" \
    -d "{\"key\":\"$TEST_KEY\",\"email\":\"$TEST_EMAIL\",\"device_hash\":\"$HASH\",\"device_name\":\"fake-dev-$i\",\"app_version\":\"1.0.0\"}" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print("activate -", r.get("status"))'
done

REAL_DEVICE_HASH=...  # 38-A と同じ Swift one-liner で取得
curl -s -w "[HTTP %{http_code}]" -X POST http://localhost:8787/v1/license/activate -H "Content-Type: application/json" \
  -d "{\"key\":\"$TEST_KEY\",\"email\":\"$TEST_EMAIL\",\"device_hash\":\"$REAL_DEVICE_HASH\",\"device_name\":\"4th\",\"app_version\":\"1.0.0\"}"
```

期待: 4 台目で `HTTP 409` + `{"error":"device_limit","existing_devices":[…3件…]}`。各 device の id / device_name / activated_at / last_seen_at が含まれる。

### 38-D. refund 連動 (license.status='refunded' → 次回 verify で token clear)

```bash
# 38-A 同様に clean state → activate → token.json まで通したあと、backend は動いてる前提で:
TEST_KEY="polepole-PHA9-TEST-EFGH-JKMN"
pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "UPDATE license SET status = 'refunded' WHERE id = '$TEST_KEY';"

pkill -9 -f "PolePole Dev" || true; sleep 1
FAKE_8D=$((ISSUED_AT + 8*86400))
POLEPOLE_TEST_LICENSE_FAKE_NOW=$FAKE_8D POLEPOLE_BACKEND_URL="http://127.0.0.1:8787" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app/Contents/MacOS/PolePole Dev" &
sleep 5
grep -E "verify rejected|state = " "$HOME/Library/Logs/polepole-dev/polepole-dev-$(date -u +%Y-%m-%d).log" | tail -3
test -f "$HOME/Library/Application Support/polepole-dev/token.json" \
  && echo "FAIL: token.json still exists" \
  || echo "PASS: token.json removed by verify reject path"
```

期待:
- ログに `[license] state = activated (expires in 22 days)` の直後に `[license] verify rejected, clearing token` → `[license] state = trial(14 days left)`
- `token.json` が消えている (verify reject 経路で `ActivationTokenStore.clear()` が呼ばれた)
- Keychain `activation-token` も消えている

### 38-E. Stripe webhook E2E (Stripe CLI + 実 test card 購入、半自動)

```bash
# 1) Sandbox API key で stripe listen を起動 (バックグラウンド)
SK=$(grep "^STRIPE_SECRET_KEY=" backend/.dev.vars | sed 's/STRIPE_SECRET_KEY="\(.*\)"/\1/')
stripe listen --api-key "$SK" --forward-to localhost:8787/stripe-webhook >/tmp/stripe-listen.log 2>&1 &
sleep 4
WHSEC=$(grep -o "whsec_[A-Za-z0-9]*" /tmp/stripe-listen.log | head -1)

# 2) .dev.vars の STRIPE_WEBHOOK_SECRET を WHSEC で上書きして backend 再起動
python3 -c "
import re, pathlib
p = pathlib.Path('backend/.dev.vars')
p.write_text(re.sub(r'^STRIPE_WEBHOOK_SECRET=.*\$', 'STRIPE_WEBHOOK_SECRET=\"$WHSEC\"', p.read_text(), count=1, flags=re.M))
"
pkill -f "wrangler" || true; sleep 1
(cd backend && pnpm dev >/tmp/wrangler-phaseB.log 2>&1 &)
sleep 5

# 3) Payment Link URL を取得 + success_url を localhost に一時切替
LINK_ID=$(grep "^EXPECTED_PAYMENT_LINK_ID=" backend/.dev.vars | sed 's/EXPECTED_PAYMENT_LINK_ID="\(.*\)"/\1/')
stripe payment_links update "$LINK_ID" --api-key "$SK" \
  -d "after_completion[type]=redirect" \
  -d "after_completion[redirect][url]=http://localhost:8787/thanks?session_id={CHECKOUT_SESSION_ID}"
stripe payment_links retrieve "$LINK_ID" --api-key "$SK" | grep "buy.stripe.com"
```

4) **人間タスク**: 上記で出る `https://buy.stripe.com/test_...` を Safari / Chrome / 任意のブラウザで開いて、test card で購入する:
   - メールアドレス: 任意 (例 `phase9-webhook@example.com`)
   - カード番号: `4242 4242 4242 4242`
   - 有効期限: `12 / 30` (任意の将来日)
   - CVC: `123`
   - 名義: 任意 (例 `Test User`)
   - 国: 日本のまま
   - **AI からの自動入力 + submit は Stripe Agent Disclosure が起動して進めない** ので、必ず人間が押す

```bash
# 5) /thanks redirect が表示されたら、AI 側で検証
echo "----- stripe listen -----"; grep "checkout.session.completed" /tmp/stripe-listen.log | tail -1
echo "----- backend (購入直後メール) -----"; grep "resend disabled" /tmp/wrangler-phaseB.log | tail -1
echo "----- D1 license -----"
(cd backend && pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "SELECT id, email, status, email_sent_at FROM license ORDER BY created_at DESC LIMIT 1;")

# 6) 検証完了後、Payment Link の success_url を本番ドメインに戻す
stripe payment_links update "$LINK_ID" --api-key "$SK" \
  -d "after_completion[type]=redirect" \
  -d "after_completion[redirect][url]=https://polepole.dev/thanks?session_id={CHECKOUT_SESSION_ID}"
```

期待:
- stripe listen ログに `checkout.session.completed [evt_...]`
- backend ログに `[resend disabled] would send to=<email> subject="【PolePole】ご購入ありがとうございます — ライセンスキーをお届けします"`
- /thanks ページに「PolePole をご購入いただきありがとうございます」見出し + メアド + ライセンスキー
- D1 に新規 license 行 (status=active, email_sent_at がタイムスタンプ入り)

### 38-F. Stripe refund 連動 (CLI から refund 実行、自動)

38-E の続きで実行。

```bash
SK=$(grep "^STRIPE_SECRET_KEY=" backend/.dev.vars | sed 's/STRIPE_SECRET_KEY="\(.*\)"/\1/')
# 38-E で作った license の payment_intent を取得
PI_ID=$(cd backend && pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "SELECT stripe_payment_intent_id FROM license ORDER BY created_at DESC LIMIT 1;" --json \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]["results"][0]; print(r["stripe_payment_intent_id"])')

# CLI から refund 実行 → webhook 経由で markRefunded が走る
stripe refunds create --api-key "$SK" -d "payment_intent=$PI_ID"

sleep 3
echo "----- stripe listen -----"; grep "charge.refunded\|refund.created" /tmp/stripe-listen.log | tail -2
echo "----- D1 license status -----"
(cd backend && pnpm exec wrangler d1 execute polepole-licenses --local --persist-to .wrangler/state \
  --command "SELECT id, status FROM license ORDER BY created_at DESC LIMIT 1;")
```

期待: stripe listen に `refund.created` + `charge.refunded` が来る、D1 license.status が `refunded` に変わる。続いて 38-D 手順 (activate → FAKE_NOW=issued_at+8d で起動 → verify reject) と同じ流れで、アプリ側が refund を検知して token を clear することを確認する。

## 39. 本番 polepole.dev smoke test (Phase 9 C)

### 39-A. ブラウザ経由の smoke test (推奨、agent-browser)

```bash
# Claude Code の Bash sandbox 内では curl が DNS 引けないので agent-browser を使う
for path in / /legal/terms /healthz "/thanks"; do
  agent-browser --session smoke open "https://polepole.dev${path}"
  agent-browser --session smoke get title
  agent-browser --session smoke get url
  echo "---"
done
agent-browser --session smoke close
```

期待:
- `/` → タイトル「PolePole — Claude Code をストレスなく回す macOS ワークスペース」
- `/legal/terms` → タイトル「利用規約 — PolePole」、URL は `.html` 拡張子なしに正規化 (Workers Assets の auto trailing-slash 挙動)
- `/healthz` → JSON `{"ok":true,"name":"polepole-backend","time":"..."}`
- `/thanks` (no param) → エラーページ "session_id がありません。購入完了ページから来てください。"

### 39-B. ターミナル経由の smoke test (sandbox 外の terminal で)

`! ` プレフィックスでユーザー側 terminal から実行 (Claude Code Bash sandbox 内では DNS 引けないため):

```bash
! curl -s -o /tmp/lp.html -w "HTTP %{http_code} size=%{size_download}B\n" https://polepole.dev/
! curl -s https://polepole.dev/healthz
! curl -s -o /dev/null -w "HTTP %{http_code} (期待 400)\n" https://polepole.dev/thanks
! curl -s -o /dev/null -w "HTTP %{http_code} (期待 400)\n" -X POST https://polepole.dev/stripe-webhook
```

期待: 順に 200 / JSON / 400 / 400。

### 39-C. Cloudflare DNS の最低構成 (回復時の参照)

Workers Routes 経由で apex を受けるには、DNS タブに以下が必要:

| Type | Name | Content | Proxy |
|---|---|---|---|
| AAAA | @ (polepole.dev) | `100::` | Proxied (orange) |

加えて Resend ドメイン認証で `send.polepole.dev` 配下に MX / TXT が入る (Auto configure で自動)。

## 40. 空状態 UI とプロジェクトインポート

### 40-A. EmptyHubView の表示 (実データ非破壊)

`POLEPOLE_TEST_AUTO_EMPTY_HUB=1` で既存プロジェクトの有無に関係なく中央ペインを EmptyHubView に差し替える。

```bash
# fixture を作る
FIX=/tmp/polepole-import-fixture
rm -rf "$FIX"; mkdir -p "$FIX"/{conventional/ghq/github.com/foo,cmux,tmuxinator,vscode,cursor}
mkdir -p "$FIX/conventional/ghq/github.com/foo/"{repo-a/.git,repo-b/.git}
mkdir -p "$FIX/conventional/ghq/github.com/bar/repo-c/.git"
cat > "$FIX/cmux/session.json" << JSON
{"createdAt":0,"version":1,"windows":[{"tabManager":{"workspaces":[
  {"currentDirectory":"$FIX/conventional/ghq/github.com/foo/repo-a","customTitle":"Pinned Repo A","isPinned":true},
  {"currentDirectory":"$FIX/conventional/ghq/github.com/bar/repo-c","customTitle":null,"isPinned":false}
]}}]}
JSON
cat > "$FIX/tmuxinator/sample.yml" << YML
name: sample
root: $FIX/conventional/ghq/github.com/foo/repo-b
YML
cat > "$FIX/vscode/storage.json" << JSON
{"openedPathsList":{"entries":[
  {"folderUri":"file://$FIX/conventional/ghq/github.com/foo/repo-a"},
  {"folderUri":"file://$FIX/conventional/ghq/github.com/foo/repo-b"}
]}}
JSON

# 起動
pkill -x "PolePole Dev" >/dev/null 2>&1 || true
open -n --env POLEPOLE_TEST_AUTO_EMPTY_HUB=1 --env POLEPOLE_TEST_IMPORT_FIXTURE="$FIX" \
  "/tmp/polepole-build/Build/Products/Debug/PolePole Dev.app"
sleep 3
osascript -e 'tell application id "local.d0ne1s.polepole.dev" to activate'
sleep 2

# Dev のメインウィンドウだけ撮る (CGWindowList から title="PolePole Dev" を引く)
scripts/polepole-screenshot.sh /tmp/polepole-emptyhub.png || true
```

期待:
- スクショに `Get started with PolePole` 見出し、`Choose a folder…` / `Import projects (3)` ボタン、`cmux 2 · local 3 · tmuxinator 1 · VS Code 2` の内訳、`How to use PolePole` リンク
- ログに `[import] scan started with 5 source(s)` → 各 source の `found=N` → `scan done candidates=3 alreadyImported=0`
- `~/Library/Application Support/polepole-dev/projects.json` は変化なし (フラグは表示専用)

```bash
grep '\[import\]' "$HOME/Library/Logs/polepole-dev/"polepole-dev-*.log | tail -10
```

### 40-B. プロジェクト 1 件以上ある状態で scan が走らないこと

`POLEPOLE_TEST_AUTO_EMPTY_HUB` を外して通常起動 (projects.json に 1 件以上ある前提)。`[import]` ログが一切出ないこと。

### 40-C. Cursor / cmux 未インストール環境のシミュレーション

fixture から `cursor/storage.json` を削除して再起動。`[import] source=cursor found=0` が出るがエラー toast は出ない。同様に cmux/session.json を消すと `source=cmux found=0`。

### 40-D. Settings の Import タブ (既存ユーザー導線、目視)

PolePole Dev 起動中に `Cmd+,` → Settings ウィンドウの `Import` タブを開く。同じ scan が走って候補リストが表示される。`Import N selected` で取り込むと `~/Library/Application Support/polepole-dev/projects.json` に末尾追加される (`cat ... | jq '.projects[].path'`)。

```bash
jq '.projects | length, [.[] | {path, isPinned, displayName}]' \
  "$HOME/Library/Application Support/polepole-dev/projects.json"
```

期待: cmux 由来で `isPinned=true` だったエントリは PolePole 側でも `isPinned=true`、cmux の `customTitle` (`Pinned Repo A` など) が `displayName` に入る。

### 40-E. Unit test

```bash
xcodebuild -project polepole.xcodeproj -scheme polepole \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/polepole-build test 2>&1 | grep -E "Test Case|Executed"
```

期待: `Executed ... tests, with 0 failures`。

## 41. Cmd+Q 終了確認ダイアログ（自動）

`applicationShouldTerminate` の NSAlert。quit Apple Event でも同じ経路を通るのでキーストローク不要で検証できる。

```bash
./scripts/polepole-launch.sh && sleep 3

# quit を送る（ダイアログ表示中は osascript がブロックするので background で）
osascript -e 'tell application "PolePole Dev" to quit' &
sleep 2

# ダイアログが別ウィンドウで出る（polepole-screenshot.sh はメインウィンドウしか撮らない点に注意）
osascript -e 'tell application "System Events" to tell process "PolePole Dev" to get name of windows'
# 期待: 空名の dialog ウィンドウ + "PolePole Dev"

# キャンセル → 生存
osascript -e 'tell application "System Events" to tell process "PolePole Dev" to click button "キャンセル" of window 1'
sleep 2 && pgrep -f "PolePole Dev.app/Contents/MacOS/PolePole Dev" && echo "ALIVE: pass"

# 再 quit → 終了ボタン → 死亡
osascript -e 'tell application "PolePole Dev" to quit' &
sleep 2
osascript -e 'tell application "System Events" to tell process "PolePole Dev" to click button "終了" of window 1'
sleep 2 && { pgrep -f "PolePole Dev.app/Contents/MacOS/PolePole Dev" || echo "TERMINATED: pass"; }
```
