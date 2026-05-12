# Step1 cmux ソース調査メモ

PoC で実装するときに参照すべき cmux のファイルと、libghostty の主要 API を控える。

cmux: `https://github.com/manaflow-ai/cmux`

ローカル: `/Users/d0ne1s/ide/.refs/cmux/` に shallow clone 済み（submodule は未取得）。

---

## ビルド・依存方式

cmux は **GhosttyKit.xcframework を Xcode プロジェクトにリンク**する方式。

- `ghostty/` は git submodule（`manaflow-ai/ghostty` のフォーク）。submodule 内の C ヘッダは `ghostty/include/ghostty.h`
- Bridging Header (`cmux-Bridging-Header.h`) で `#include "ghostty/include/ghostty.h"` し Swift から C API を直接呼ぶ
- xcframework の生成方法は2通り（`scripts/ensure-ghosttykit.sh`）:
  1. **prebuilt をダウンロード**: `manaflow-ai/ghostty` の Release（タグ `xcframework-<sha>`）から `.tar.gz` を取得し SHA256 を pin したマニフェストで検証（`scripts/ghosttykit-checksums.txt`）
  2. **ローカルビルド**: `cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast`（zig が必要）
- xcframework は `ghostty/macos/GhosttyKit.xcframework` に出力され、プロジェクトルートに symlink される
- ビルド後の Xcode の Run Script Phase で `ghostty/zig-out/share/ghostty`（リソース）と `ghostty/zig-out/share/terminfo` を `.app/Contents/Resources/` にコピー（実行時に環境変数 `GHOSTTY_RESOURCES_DIR` / `TERMINFO` で参照）

### PoC での選択

- 最初は **upstream（ghostty-org/ghostty）** の xcframework で進める。リサイズ ちらつき や ディスプレイ変更 の安定化が必要になったら cmux fork に切り替える
- `docs/ghostty-fork.md` の section 1, 2 がリサイズ・ディスプレイの修正、section 8 が kitty graphics、section 10 が iOS 用の manual IO（embedder 側 PTY）。**section 10 は不要**（PoC は内蔵 PTY を使う）
- 自前ビルドを避けたければ cmux 同様 prebuilt を pin して取り回せばよい

---

## libghostty C API（ghostty.h）

`/tmp/ghostty.h` に `manaflow-ai/ghostty/main` の最新版（1231行）を取得済み。主要関数:

### App 全体（プロセス1個）

```c
int ghostty_init(uintptr_t argc, char** argv);                       // プロセス init
ghostty_config_t ghostty_config_new(void);                           // 空 config
void ghostty_config_load_default_files(ghostty_config_t);            // ★ ~/.config/ghostty/config を自動読込
void ghostty_config_load_recursive_files(ghostty_config_t);          // include 解決
void ghostty_config_load_file(ghostty_config_t, const char*);        // 個別ファイル
void ghostty_config_load_string(ghostty_config_t, const char*, ...); // 文字列上書き
void ghostty_config_finalize(ghostty_config_t);                      // 確定
ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*, ghostty_config_t);
void ghostty_app_tick(ghostty_app_t);                                // wakeup_cb から呼ぶ
void ghostty_app_set_focus(ghostty_app_t, bool);                     // NSApp didBecomeActive 等で
void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);     // ⌘⇧, リロード
```

`ghostty_runtime_config_s` のコールバック:
- `wakeup_cb(userdata)` → メインスレッドで `ghostty_app_tick()` を呼ぶようスケジュール
- `action_cb(app, target, action)` → タイトル変更・色変更・ベル・URL オープン等の通知（PoC は最低限のみ処理）
- `read/confirm_read/write_clipboard_cb` → ペーストボード接続
- `close_surface_cb(userdata, needsConfirm)` → 子プロセス終了通知

### Surface（タブ1個＝ターミナル1個）

```c
ghostty_surface_config_s ghostty_surface_config_new(void);   // デフォルト値
ghostty_surface_t ghostty_surface_new(ghostty_app_t, const ghostty_surface_config_s*);
void ghostty_surface_free(ghostty_surface_t);
void ghostty_surface_set_size(ghostty_surface_t, uint32_t wpx, uint32_t hpx);  // ピクセル単位
void ghostty_surface_set_content_scale(ghostty_surface_t, double, double);     // Retina
void ghostty_surface_set_focus(ghostty_surface_t, bool);
void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);              // CGDirectDisplayID
bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);              // キー入力
void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);          // IME 確定文字列
void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);       // IME 未確定
bool ghostty_surface_mouse_button(ghostty_surface_t, action, button, mods);
void ghostty_surface_mouse_pos(ghostty_surface_t, double x, double y, mods);
void ghostty_surface_mouse_scroll(ghostty_surface_t, ...);
void ghostty_surface_ime_point(ghostty_surface_t, double*, double*, double*, double*);
```

`ghostty_surface_config_s` の重要フィールド（PoC で使うもの）:
- `platform_tag` = `GHOSTTY_PLATFORM_MACOS`
- `platform.macos.nsview` = 描画先 NSView の `Unmanaged.passUnretained(view).toOpaque()`
- `userdata` = コールバックコンテキスト（任意）
- `scale_factor` = レイヤの `contentsScale`
- `font_size` = config からの初期値
- `working_directory` = プロジェクトルート
- `command` = nil なら user shell（`$SHELL -l`）
- `env_vars` / `env_var_count` = 環境変数追加
- `initial_input` = 起動時に流し込むテキスト（PoC では nil）
- `io_mode` = `GHOSTTY_SURFACE_IO_EXEC`（=0、デフォルト。Ghostty が PTY を内部管理する）
  - **注**: `IO_MANUAL` は cmux fork 専用。upstream には未マージ

PTY は libghostty 内部で fork+exec されるため、PoC で自前で `forkpty()` する必要は**ない**。

---

## cmux 側 Swift ラッパーの構造

参照すべきファイル（path は `/Users/d0ne1s/ide/.refs/cmux/` 配下、行番号は 2026-05-08 時点の HEAD）:

| ファイル | 内容 | 行数 | 必読範囲 |
|---|---|---|---|
| `ghostty.h`（プロジェクトルート） | `@import GhosttyKit;` するだけのトップヘッダ | 8 | 全部 |
| `cmux-Bridging-Header.h` | Swift bridging header の本体 | 7 | 全部 |
| `Sources/GhosttyTerminalView.swift` | **本丸**: `GhosttyApp`/`TerminalSurface`/`GhosttyNSView`/`GhosttyTerminalView`(NSViewRepresentable) | 13458 | 下表参照 |
| `Sources/GhosttyConfig.swift` | テーマ・フォント・色情報を Ghostty config から取り出す Swift モデル | 759 | 1–120 |
| `Sources/GhosttyTextInputSupport.swift` | キーイベント変換ヘルパ（`ghostty_input_key_s` 構築） | 148 | 全部 |
| `Sources/GhosttyNSView+IMEComposition.swift` | IME（日本語入力）の preedit 整合 | 66 | 全部 |
| `Sources/GhosttyTerminalAppearance.swift` | 背景・ブラー等の見た目調整 | 108 | 流し読み |
| `Sources/TerminalStartupEnvironment.swift` | Surface 起動時の環境変数マージ | 51 | 全部 |
| `scripts/ensure-ghosttykit.sh` | xcframework 取得/ビルド | 260 | 全部 |
| `docs/ghostty-fork.md` | cmux fork が upstream に対して持つ patch 一覧 | 290 | 全部 |

`GhosttyTerminalView.swift` の中の重要セクション（参照ピン）:

| 行 | シンボル | 内容 |
|---|---|---|
| 1394 | `GhosttySurfaceCallbackContext` | 各 surface のコールバック context |
| 1419 | `class GhosttyApp` | プロセス全体のシングルトン |
| 1733 | `ghostty_init` 〜 `ghostty_app_new` | **初期化シーケンス全部**（PoC のテンプレ） |
| 1757 | `var runtimeConfig = ghostty_runtime_config_s()` | runtime コールバック設定 |
| 1995 | `loadDefaultConfigFilesWithLegacyFallback` | 設定継承（`ghostty_config_load_default_files`） |
| 2801 | `ghostty_app_tick(app)` 呼び出し | wakeup から tick |
| 4126 | `final class TerminalSurface` | surface ラッパー（巨大） |
| 4821 | `private func createSurface(for view:)` | **surface 作成シーケンス**（surface_config 組み立て、env、PTY コマンド、`ghostty_surface_new`） |
| 5793 | `class GhosttyNSView: NSView` | レンダリング先 NSView（`acceptsFirstResponder` 等） |
| 12523 | `extension GhosttyNSView: NSTextInputClient` | IME 連携の本体（`insertText`/`setMarkedText`/`firstRectForCharacterRange` 等） |
| 12996 | `struct GhosttyTerminalView: NSViewRepresentable` | **SwiftUI ブリッジ**（PoC のテンプレ） |

cmux は `NSViewRepresentable` 配下に「portal」レイヤ（`HostContainerView` / `TerminalWindowPortal`）を仕込んで AppKit 側で別ウィンドウに描画している。**これは複数ペイン+SwiftUI 階層の競合を回避するための最適化で、PoC では不要**。`makeNSView` で `GhosttyNSView` を直接返す素朴な実装で問題ない。

---

## PoC 最小構成の手順（step3〜4 で実装する）

1. `ghostty_init(argc, argv)` を 1 回だけ呼ぶ（`@main` 直後）
2. `ghostty_config_new()` → `ghostty_config_load_default_files(config)` → `ghostty_config_load_recursive_files(config)` → `ghostty_config_finalize(config)`
   - これだけで `~/.config/ghostty/config` が読まれる（要件 step5 の核）
3. `ghostty_runtime_config_s` を組み立て:
   - `wakeup_cb`: `DispatchQueue.main.async { ghostty_app_tick(app) }`
   - `action_cb`: タイトル変更だけ拾って NSWindow.title に反映、それ以外は無視
   - `write_clipboard_cb` / `read_clipboard_cb` / `confirm_read_clipboard_cb`: `NSPasteboard` 読み書きのみ
   - `close_surface_cb`: タブを閉じる
4. `ghostty_app_new(&runtime, config)` で app 取得
5. `NSViewRepresentable.makeNSView` で `GhosttyNSView`（自作）を返す:
   - `wantsLayer = true` / `acceptsFirstResponder = true`
   - `viewDidMoveToWindow` で `ghostty_surface_new` を発行（surface_config に nsview ポインタを渡す）
   - `NSEvent` ベースで `ghostty_surface_key` / `ghostty_surface_text` / `ghostty_surface_mouse_*` を呼ぶ
   - `setFrameSize` で `ghostty_surface_set_size(surface, wpx, hpx)`（ピクセル単位なので `convertToBacking` する）
   - IME は `NSTextInputClient` を実装し、`setMarkedText` → `ghostty_surface_preedit`、`insertText` → `ghostty_surface_text`
6. `ghostty_surface_set_focus` を `NSWindow.makeFirstResponder` の前後で正しく送る

---

## 撤退判断シグナルの確認軸

step1 を経た時点で、撤退ライン（`docs/plans/poc-libghostty.md` 想定リスク表）に対する見立て:

- ✅ **ビルド方法は明確**: prebuilt xcframework 経路があるので zig 必須ではない。詰む確率は低い
- ✅ **C → Swift bridging は cmux のテンプレを流用**できる。型変換でハマっても `cmux-Bridging-Header.h` + `ghostty.h` をそのまま再利用すれば済む
- ✅ **`~/.config/ghostty/config` 継承の API は確定**（`ghostty_config_load_default_files`）。step5 はここを呼ぶだけで通る見込み
- ⚠️ **入力イベント・IME は cmux ですらコード量が多い**（`GhosttyTextInputSupport.swift` + IMEComposition + `NSTextInputClient` 約200行）。PoC で「日本語入力できる」までやろうとするとこの部分の写経が一番ボリュームになる

---

## 追加調査メモ（step1 second pass）

### A. 入力/IME 経路（GhosttyTerminalView.swift L7258 以降）

cmux の `keyDown(with:)` は以下の段階を踏む:

1. **Ctrl-key fast path** (L7355-7417): `flags == .control` のときは AppKit の `interpretKeyEvents` を経由せず、直接 `ghostty_surface_key` に投げる。split close/reparent 時に `keyDown` が落ちる事象の対策
2. **mods translation** (L7421-7461): `ghostty_surface_key_translation_mods(surface, mods)` で Ghostty config（`macos-option-as-alt` 等）に従ってモディファイア書き換え。書き換え後の `NSEvent` を新しく作り直して `interpretKeyEvents` に渡す
3. **`keyTextAccumulator = []`** (L7464): `NSTextInputClient.insertText` で挿入される文字列を貯めるバッファをセット
4. **`interpretKeyEvents([translationEvent])`** (L7484): AppKit の IME パイプラインを起動。これが `setMarkedText` / `insertText` を呼び出す
5. **キーボード配列変化検知** (L7494-7505): `KeyboardLayout.id` が変わったら IME がイベントを掴んだとみなして preedit 同期だけして return
6. **`syncPreedit(clearIfNeeded:)`** (L7512): 現 marked text を `ghostty_surface_preedit(surface, ptr, len)` に流す
7. **`shouldSuppressGhosttyKeyForwardingAfterIMEHandling`** (L7518): IME が消費したキーは Ghostty にも送らない判定
8. **`ghostty_input_key_s` 構築** (L7522-7530):
   - `action` = `GHOSTTY_ACTION_PRESS` / `REPEAT` (`event.isARepeat`)
   - `keycode` = `UInt32(event.keyCode)`
   - `mods` = `modsFromEvent(event)` (cmux 内のモディファイア変換)
   - `consumed_mods` = `consumedModsFromFlags(translationMods)` (Control/Command は text translation に寄与しない)
   - `unshifted_codepoint` = `unshiftedCodepointFromEvent(event)`
   - `composing` = `markedText.length > 0 || markedTextBefore`
9. **送信分岐**:
   - `accumulatedText` が非空（IME 確定文字列がある）→ 各文字を `text=ptr` 付きで `ghostty_surface_key` に送る（`composing = false` に上書き）
   - そうでなく `textForKeyEvent` が text を返す → `text=ptr` 付きで送る
   - text なし → `text=nil` で送る（Ghostty 側で keycode のみ encoding）
10. **`forceRefresh`** (L7697): テキスト入力後の即時再描画

`NSTextInputClient` 拡張 (L12523+) の重要メソッド:
- **`sendTextToSurface(chars:preserveLiteralEscape:)`** (L12528): プログラム的にテキストを流すための共通パス。`\n`/`\r` → `kVK_Return` (0x24)、`\t` → `kVK_Tab` (0x30)、ESC → `kVK_Escape` (0x35) に分解。残りは `keyEvent.text = ptr` でまとめて送る
- **`insertText`**（直下にあるはず）→ 実際には `keyTextAccumulator` に貯めるだけで、後段の `keyDown` 末尾でまとめて Ghostty に送る
- **`setMarkedText` / `unmarkText`** → `markedText` を更新 → `syncPreedit` 経由で `ghostty_surface_preedit`
- **`firstRectForCharacterRange`** → `ghostty_surface_ime_point` で IME ポップアップ位置を取得

#### PoC で写すべき最小セット

完全コピーは過剰。PoC は次の縮約版で十分:

```
keyDown:
  keyTextAccumulator = []
  let beforeMarked = !markedText.isEmpty
  interpretKeyEvents([event])
  syncPreedit()  // markedText → ghostty_surface_preedit
  if markedText changed since before → return  // IME が消費した
  build ghostty_input_key_s with action/keycode/mods
  if accumulatedText: 各 text を keyEvent.text に詰めて ghostty_surface_key
  else if textForKeyEvent: text 付きで ghostty_surface_key
  else: text=nil で ghostty_surface_key
```

省ける機能（PoC では不要）:
- Ctrl-key fast path（split reparent しないので drops しない）
- `translation_mods` の書き換え（macos-option-as-alt が要らないなら）
- numpad IME commit dedup（極小ケース）
- keyboard layout 変化検知（実害が出るのは IME 切替の瞬間のみ）

これで日本語入力含む基本動作はカバーできる見込み。

### B. 描画/レンダリング（CAMetalLayer ベース）

要点: **ghostty 側がレンダラを持つので Swift 側は CAMetalLayer を提供して NSView ポインタを渡すだけ**。

cmux の `GhosttyNSView.makeBackingLayer()` (L5991-6001):

```swift
override func makeBackingLayer() -> CALayer {
    let metalLayer = CAMetalLayer()
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.isOpaque = false
    metalLayer.framebufferOnly = false  // 透過/ブラー時に compositor が drawable を読むため
    return metalLayer
}

private func setup() {
    wantsLayer = true
    layer?.masksToBounds = true
}
```

Metal layer の lifecycle:
- `viewDidChangeBackingProperties` (L6253) → `layer?.contentsScale = window.backingScaleFactor`
- リサイズ時 (L6431-6437) → `metalLayer.drawableSize = drawablePixelSize` を手動更新（自動でない）
- `GhosttyMetalLayer: CAMetalLayer` (L4026) は `nextDrawable` を lock でラップしたデバッグ専用版。**通常は stock `CAMetalLayer` を使う**（L5992 のコメント参照）
- IOSurface は **新フレーム検知用**（debug stats、L9569）。実際の描画は Ghostty の Metal renderer が presentDrawable する

PoC では `makeBackingLayer` で `CAMetalLayer` を返し、`wantsLayer = true` するだけでよい。

### C. PTY / リサイズ追従

PTY は Ghostty 内蔵。Swift 側がやることは:

```swift
override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    let scale = window?.backingScaleFactor ?? 1
    layer?.contentsScale = scale
    if let surface {
        ghostty_surface_set_content_scale(surface, scale, scale)
    }
    syncSize()
}

override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncSize()
}

private func syncSize() {
    guard let surface else { return }
    let backing = convertToBacking(bounds).size
    let wpx = UInt32(max(0, backing.width.rounded()))
    let hpx = UInt32(max(0, backing.height.rounded()))
    guard wpx > 0, hpx > 0 else { return }
    ghostty_surface_set_size(surface, wpx, hpx)
    (layer as? CAMetalLayer)?.drawableSize = CGSize(width: Double(wpx), height: Double(hpx))
}
```

cmux 実装（L5118-5223）の補足:
- 初回 surface 作成直後にも `set_content_scale` → `set_size` を呼ぶ（L5118-5123）
- `lastPixelWidth`/`lastPixelHeight` で前回値と比較し、変化なしなら no-op（無駄な ioctl 抑制）
- `ghostty_surface_set_display_id(surface, CGDirectDisplayID)` を `viewDidMoveToWindow` で呼んで複数ディスプレイ対応（外部モニタの ProMotion 等の vsync 切替）
- TIOCSWINSZ は **Ghostty 側で自動**。`set_size` のピクセルサイズと cell_size から rows/cols を計算して PTY に伝搬する

### D. upstream Ghostty と fork の差

`/tmp/ghostty.h`（manaflow fork）と `/tmp/ghostty-upstream.h`（ghostty-org/ghostty main）の API 差分:

fork のみで上流にない関数:
- `ghostty_surface_clear_selection` / `ghostty_surface_select_cursor_cell` ← cmux のキーボードコピーモード用（PoC 不要）
- `ghostty_config_load_string(config, str, len, label)` ← インライン文字列で config 上書き（PoC 不要、`load_default_files` で十分）
- `ghostty_surface_process_output` / `ghostty_surface_render_now` / `ghostty_surface_text_input` ← cmux iOS 向け manual IO（PoC 不要）
- `ghostty_io_write_cb` typedef + `ghostty_surface_io_mode_e` enum ← 同上

#### 結論

PoC は **upstream Ghostty の xcframework で十分**。理由:
- 上記 fork-only API は PoC スコープ外（コピーモード、iOS、in-memory config 上書き）
- 設定継承・PTY 起動・1タブ表示・入力 IME はすべて upstream API のみで実装可能

例外（fork に切替を検討する条件）:
- ウィンドウリサイズ時に **画面のちらつきが目立つ** → fork section 2 (resize stale-frame mitigation)
- 外部ディスプレイ抜き差し後にターミナルが固まる → fork section 1 (display link restart)
- BEL 通知（要件 4 の AI 完了通知）で **OSC 99** を使いたくなったら → fork section 3（ただし要件は **BEL 0x07** で済む方針なので不要見込み）

upstream の prebuilt xcframework が GitHub Release で公開されているかは **未確認**。なければ自前で zig build するか cmux fork の prebuilt を使う必要がある（後者なら追加の patch も同梱されるが PoC では悪さしない）。

### 修正された step1 サマリ

- **入力/IME**: cmux の写経範囲は約 200 行で、簡略版なら 80-100 行で日本語 IME 含む基本動作カバー可能
- **描画**: CAMetalLayer 1個提供するだけ。**実装ボリュームは10行未満**
- **リサイズ**: `setFrameSize` + `viewDidChangeBackingProperties` + `viewDidMoveToWindow` で `set_size` / `set_content_scale` / `set_display_id` を呼ぶ。**実装ボリューム30行未満**
- **upstream で開始**、ちらつきや凍結が出たら fork に乗り換えるという方針で OK
