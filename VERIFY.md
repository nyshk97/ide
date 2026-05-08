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

## 6. TUI 動作確認

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
