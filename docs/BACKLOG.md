# BACKLOG

ide の今後の着手候補。基本機能は一通り揃っているので、ここにあるのは「やりたくなったら / 必要を感じたら」のリスト。優先度で 3 段に分ける（要件番号は [REQUIREMENTS.md](../REQUIREMENTS.md) を参照）。

コード整理寄りのタスク（`ProcessRunner` 集約、`setActive` の永続化外し、`FilePathKey` 導入、プレビューのサイズ判定など）は [SIMPLIFICATION_OPPORTUNITIES.md](./SIMPLIFICATION_OPPORTUNITIES.md) の P0/P1/P2 を参照。こちらは主に「機能」の残タスクを置く。

---

## 優先度: 高め（コスパが良い・効果が見えている）

| 項目 | 一言 |
|---|---|
| `PocLog`（`/tmp/ide-poc.log`）→ `Logger`（`~/Library/Logs/ide/`）一本化 | 現状 `PocLog.write` が stderr + `/tmp` + `Logger.debug` の 3 経路に出していて、`Logger` 自身も stderr に書くので二重出力になっている。call site を `Logger.shared.debug` に置換するだけ。`SIMPLIFICATION_OPPORTUNITIES.md` P1-5 と同じ。`Logger` は十分安定しているので着手可 |

> いまのところ「機能」面で高優先と言い切れるものはこれくらい。基本機能には満足しているので、無理に下の表を消化しにいく必要はない。

---

## 優先度: 低め（必要を感じてから・シグナル待ち）

「着手の合図」が来たら上の表に格上げする。

| 項目 | 関連 step | 着手の合図 / 補足 |
|---|---|---|
| FSEvents によるファイルツリー差分反映 | step7 | 新規ファイル作成・削除がツリーに即時反映されるように。**ツリーの手動 reload が頻繁に必要になったら最優先**。単一ファイルのプレビュー追従は kqueue（`FileChangeWatcher`）で実装済み、ツリーだけ未対応。FSEvents は実装量が大きいので独立タスク扱い |
| プレビューのスクロール位置保持（行番号基準）+ 削除時の明示表示 | step8 | 自動リロード自体は実装済み。リロードで WebView が作り直されてスクロール位置が飛ぶのと、表示中ファイルが削除されたとき古い内容が残るのを直す。**リロードのたびスクロールが飛んで困る体験が複数回あったら** |
| Cmd+Shift+F の結果から該当行へジャンプ | step11 | 中工数（プレビュー側に scroll-to-line の仕組みが要る）。**全文検索を使っていて、ヒット行に飛べないのが不便だと感じたら** |
| Cmd+P で Cmd+C パスコピー | step10 | 小。手が伸びたら入れる |
| Cmd+Shift+F で Cmd+C パスコピー | step11 | 小。手が伸びたら入れる |
| ファイルツリーの「ターミナルで開く」を直接 `cd` 送信に | — | 現状は pasteboard コピーだけ（しかもパスが shell エスケープされていない）。`SIMPLIFICATION_OPPORTUNITIES.md` P1-8 参照。短期は `shellEscape` 流用、中期は active surface に `cd -- <path>\n` 直送。**このメニューを使うようになったら**。ほぼ使わないなら放置可 |
| ripgrep バンドリング | step11 | 現状 macOS 標準 grep で代用。**検索が grep だと体感で耐えられなくなったら**。その前に `SIMPLIFICATION_OPPORTUNITIES.md` P1-3（stdout streaming + 1000 件で early stop）で様子見。バンドリングは hardened runtime / notarize / entitlements の検証込みで重い |
| AI 完了通知の精度向上（途中 REMOVE の debounce / 手動クリア / codex 検証） | — | 完了検知は `OSC 9;4` プログレス（作業中→REMOVE）ベースで実装済み（claude/codex はベルを鳴らさないため）。**ツール呼び出しで誤検知が出てうるさい体験があったら** debounce だけやる |

---

## 当面やらない（要件記載だが今は動機が薄い / 現設計と逆）

- **要件 5 系の AI 連携** — AI 起動ショートカット（Cmd+Shift+T）、カスタム起動テンプレート、プロンプトテンプレートのワンタッチ挿入、プランファイル連携、AI ヘルス監視（claude が応答しない検知）、クロスエージェント引き継ぎ補助。いずれも要件には記載があるが、ターミナルペインで Claude Code をそのまま使えている現状では IDE 側に作り込む動機が薄い。`/handoff` `/plot` 等は Claude Code 側のスキルでカバーできている。**「これがないと不便」と実際に感じたら**個別に上の表へ。
- **セッション復元（active project / ツリー展開 / プレビュー履歴）** — 要件 2 / 7 が「再起動時はリセット」と明示しているので現設計と逆方向。方針を変えるなら再検討。

---

## 既知の制約（タスクではない・記録用）

- `IDE_TEST_*` 環境変数が複数（`AUTO_ACTIVATE_INDEX` `AUTO_PREVIEW` `AUTO_FULLSEARCH` `TOAST`）— docs/DEV.md にまとめてある。今後増やすなら命名規約を `IDE_TEST_<feature>_<param>` に統一する、という指針だけ。
- SwiftUI の `onTapGesture` が AppleScript の `click at` に届かない — 動作確認は `IDE_TEST_*` で迂回済み。完全自動化は難しいので手動確認を VERIFY.md に残す方針で確定。
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
