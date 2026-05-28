# BACKLOG

ide の今後の着手候補。基本機能は一通り揃っているので、ここにあるのは「やりたくなったら / 必要を感じたら」のリスト。優先度で 3 段に分ける（要件番号は [REQUIREMENTS.md](../REQUIREMENTS.md) を参照）。

コード整理寄りのタスク（`ProcessRunner` 集約、`setActive` の永続化外し、`FilePathKey` 導入、プレビューのサイズ判定、`git ls-files` 化、セキュリティ quick wins、`PocLog`→`Logger` 一本化など）は [docs/plans/2026-05-12-code-cleanup-pass.md](./plans/2026-05-12-code-cleanup-pass.md) で消化済み（このプランはクローズ済み。詳細リファレンスだった `docs/SIMPLIFICATION_OPPORTUNITIES.md` は削除した — 内容は git history 参照）。やり残した長尾（除外ポリシー一元化・`ProjectsModel` 分割など）は下の「優先度: 低め」表に移した。こちら（BACKLOG）は「機能」の残タスクと、これらの長尾を置く。

---

## 優先度: 高め（コスパが良い・効果が見えている）

> いまのところ「機能」面で高優先と言い切れるものはない。基本機能には満足しているので、無理に下の表を消化しにいく必要はない。

---

## 優先度: 低め（必要を感じてから・シグナル待ち）

「着手の合図」が来たら上の表に格上げする。

| 項目 | 着手の合図 / 補足 |
|---|---|
| FSEvents によるファイルツリー差分反映 | 新規ファイル作成・削除がツリーに即時反映されるように。**ツリーの手動 reload が頻繁に必要になったら最優先**。単一ファイルのプレビュー追従は kqueue（`FileChangeWatcher`）で実装済み、ツリーだけ未対応。FSEvents は実装量が大きいので独立タスク扱い |
| プレビューのスクロール位置保持（行番号基準）+ 削除時の明示表示 | 自動リロード自体は実装済み。リロードで WebView が作り直されてスクロール位置が飛ぶのと、表示中ファイルが削除されたとき古い内容が残るのを直す。**リロードのたびスクロールが飛んで困る体験が複数回あったら** |
| Cmd+Shift+F の結果から該当行へジャンプ | 中工数（プレビュー側に scroll-to-line の仕組みが要る）。**全文検索を使っていて、ヒット行に飛べないのが不便だと感じたら** |
| ファイルツリーの「ターミナルで開く」を直接 `cd` 送信に | 現状は pasteboard コピー（パスは shell エスケープ済み）。中期は active surface に `cd -- <path>\n` 直送。**このメニューを使うようになったら**。ほぼ使わないなら放置可 |
| ripgrep バンドリング | 現状 macOS 標準 grep で代用（`maxStdoutBytes` で暴走は抑え済み）。**検索が grep だと体感で耐えられなくなったら**。バンドリングは hardened runtime / notarize / entitlements の検証込みで重い |
| AI 完了通知の精度向上（途中 REMOVE の debounce / 手動クリア / codex 検証） | 完了検知は `OSC 9;4` プログレス（作業中→REMOVE）ベースで実装済み（claude/codex はベルを鳴らさないため）。**ツール呼び出しで誤検知が出てうるさい体験があったら** debounce だけやる |
| 通知系の Diagnostics 画面 / テスト通知ボタン | 「通知が出ない」のサポート対応で `[fg]` `[progress]` `[unread]` ログを送ってもらう手間を減らす。設定画面に各タブの現在の `foregroundProgram` / 最後の OSC 9;4 event / 最後に played sound の時刻を出すパネルと、ワンクリックで sound + 赤丸を発火させる「テスト通知」ボタン。**他人の環境で通知が出ない問い合わせが複数回来たら** |
| OS 通知 (UNUserNotificationCenter) の導入検討 | 現状は in-app の赤丸 + サウンドのみ。ウィンドウが背面に回っているとき or DnD 中の通知履歴を残したいなら banner / Notification Center に出す選択肢。entitlement 追加と初回 permission request、要件「PolePole の中で完結」とのトーンとの整合性を要検討。**「アプリを最小化していると気づかない」フィードバックが来たら** |
| 起動時に「dotfiles / CloudStorage が読めない」を検出して案内する | `PolePole.app` にフルディスクアクセスが無いと PolePole 内シェルが `~/.zshrc`（→ `~/Library/CloudStorage/` の dotfiles）を `EPERM` で読めず、デフォルトプロンプト・mise 未起動・`claude` not found になる（[docs/DEV.md の TCC の節](./DEV.md#tccプライバシー権限の罠) 参照）。起動時に「`~/.zshrc` が読めない」or「`~/Library/CloudStorage/` にアクセスできない」を検出したら、要件 8.3 の常駐表示で「フルディスクアクセスを付与してください」+ System Settings（`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`）を開くボタンを出す。**次に同じ状況になったとき一発で気づける**ようにしたくなったら。同様に画面収録が無いときの案内も合わせられる |
| 検索 / ツリーの除外ポリシー一元化（整理パス P1-2） | `FileIndex` の `alwaysSkipDirNames`/`cheapSkipDirNames`（`.git` / `node_modules` / `DerivedData` / `.build`）と `FullTextSearcher` の `--exclude-dir`（+ `.refs`）がまだ別管理。`SearchPolicy` 的な enum に寄せると Cmd+P / Cmd+Shift+F / ツリーの挙動差分を見つけやすい。**ripgrep バンドリング（上の行）をやるときに一緒に**。単独でやる動機は薄い |
| `ProjectsModel` の責務分割 / foreground polling 間引き / ファイルツリーの node 探索の辞書化（整理パス P2-1〜P2-3） | いずれも現状困っていない。**`ProjectsModel` が肥大で触りづらくなったら**（list / workspace registry / search overlay / test bootstrap に分ける）/ **多タブで動作が重くなったら**（idle tab の foreground poll を 2-3 秒間隔に）/ **巨大ツリーの展開が遅いと感じたら**（`nodeByPath: [FilePathKey: FileNode]`） |
| ペイン間のタブ移動 (D&D + `Cmd+Shift+Opt+↑/↓`) | 2026-05-27 に Container 方式 (`addSubview` で reparent) で実装したが、libghostty が surface 作成時の NSView pointer / CAMetalLayer を内部で握り続けるため reparent では Metal binding が新階層に再束縛されず、移動後のタブが真っ黒になるバグで撤退。**新方針**: cmux 実装に倣って `realNSView` は window root 直下の `TerminalsHostView` に一度だけ attach し、SwiftUI 側の `TerminalAnchorView` の frame に追従させる (portal host + anchor reconcile)。設計詳細は [2026-05-27-pane-layout-and-cross-pane-tabs.md](./plans/2026-05-27-pane-layout-and-cross-pane-tabs.md) Phase 3 セクション。「2 ペイン作業中に『このタブは反対側でやりたい』と頻繁に思うようになったら」優先度を上げる |
| Release entitlement 変更の実機検証（整理パス P1-7） | `Resources/PolePole.entitlements` から `com.apple.security.automation.apple-events` を削除済み（残り 3 つの hardened runtime 例外は libghostty 由来で残置）。Release ビルド + notarize + 実機でターミナル描画 / IME / クリップボードが正常か確認する。低リスクなので単体でリリースを切らず、**次に何かの理由でリリースするタイミングに相乗り**。NG なら entitlement を戻す |
| 上下 divider のホバー時 resize cursor 表示 | 2026-05-28 に複数手法を試したが未達で撤退（drag は `dividerThickness=11` 化で掴みやすくした）。原因は「ZStack 最上層の `TerminalsHostView` が divider 領域を覆い、cursor 解決の hitTest が host→下層 NSSplitView に回るがどちらも divider cursor を担当しない」という二段構え。`addCursorRect` は前面 view に覆われた領域で無効、`NSTrackingArea(.cursorUpdate)` も hitTest nil 領域には飛ばないため対症療法が効かない。全試行錯誤は [docs/DEV.md の該当節](./DEV.md#上下-divider-にホバーしても-resize-cursor-が出ない未解決)。本命は「1 terminal = 1 lease host」構造への作り替え（full-window host を廃して cursor aggregation 面積を terminal 実体分に絞る）。**divider cursor がどうしても欲しいシグナルが来たら**着手 |

---

## 当面やらない（要件記載だが今は動機が薄い / 現設計と逆）

- **要件 5 系の AI 連携** — AI 起動ショートカット（Cmd+Shift+T）、カスタム起動テンプレート、プロンプトテンプレートのワンタッチ挿入、プランファイル連携、AI ヘルス監視（claude が応答しない検知）、クロスエージェント引き継ぎ補助。いずれも要件には記載があるが、ターミナルペインで Claude Code をそのまま使えている現状では PolePole 側に作り込む動機が薄い。`/handoff` `/plot` 等は Claude Code 側のスキルでカバーできている。**「これがないと不便」と実際に感じたら**個別に上の表へ。
- **セッション復元（active project / ツリー展開 / プレビュー履歴）** — 要件 2 / 7 が「再起動時はリセット」と明示しているので現設計と逆方向。方針を変えるなら再検討。

---

## 商用化（有償配布）を見据えた検討項目

詳細は [docs/COMMERCIALIZATION.md](./COMMERCIALIZATION.md) に分離した。MUST / SHOULD / NICE と「先に決めておくべきオープン論点」がまとまっている。

---

## 既知の制約（タスクではない・記録用）

- `POLEPOLE_TEST_*` 環境変数が複数（`AUTO_ACTIVATE_INDEX` `AUTO_PREVIEW` `AUTO_FULLSEARCH` `TOAST`）— docs/DEV.md にまとめてある。今後増やすなら命名規約を `POLEPOLE_TEST_<feature>_<param>` に統一する、という指針だけ。
- SwiftUI の `onTapGesture` が AppleScript の `click at` に届かない — 動作確認は `POLEPOLE_TEST_*` で迂回済み。完全自動化は難しいので手動確認を VERIFY.md に残す方針で確定。
- HSplitView は `idealWidth` を尊重しない — maxWidth で抑える workaround 済み（step1）。

---

## dogfooding で気付いたこと

dogfooding を進めながら追記する。日付は `YYYY-MM-DD` 形式（相対日付は使わない）。

---

## 更新ルール

- 解決した項目は次回コミットで削除する（記録は git log に残るので二重には残さない）
- 着手候補は優先度を見て「高め」「低め」の表に置く。シグナルが来たら格上げする
- 「当面やらない」に置いたものも、必要を感じたら遠慮なく格上げしてよい
- アイデアレベルの追加は「低め」か「当面やらない」に気軽に追記する
