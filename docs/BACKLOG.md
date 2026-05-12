# BACKLOG

Phase 2 完了後に残っているタスクと、今後のアイデアを集約する場所。

ステータスを 4 段階で区別する:

- 🔴 **P0**: 要件にあって、UX 上ないと困る（dogfooding で気になる確度が高い）
- 🟡 **P1**: 要件にあるが、当面なくても回る（後段に倒した小項目）
- 🟢 **P2**: 要件には未記載 or アイデア段階
- ⚪ **解決済み**: 実装が入ったらここから消す

---

## Phase 2.5（持ち越しの大物）

| Pri | 項目 | 関連 step | 一言 |
|---|---|---|---|
| 🔴 | FSEvents によるファイルツリー差分反映 | step7 | 新規ファイル作成・削除がツリーに即時反映されるように。単一ファイルのプレビュー追従は kqueue（`FileChangeWatcher`）で実装済み、ツリーだけ未対応 |
| 🟡 | プレビューのスクロール位置保持（行番号基準）+ 削除時の明示表示 | step8 | 自動リロード自体は実装済み。リロードで WebView が作り直されてスクロール位置が飛ぶのと、表示中ファイルが削除されたときに古い内容が残るのを直す |
| 🟡 | ripgrep バンドリング | step11 | 現状 macOS 標準 grep で代用。当面は `SIMPLIFICATION_OPPORTUNITIES.md` P1-3（stdout streaming + 1000 件で early stop）でしのげる。バンドリングは hardened runtime / notarize / entitlements の検証込みで重い |

### Phase 2.5 着手の合図
- dogfooding でファイルツリー差分の手動 reload が頻繁に必要になったら → FSEvents を最優先
- プレビューをリロードするたびにスクロール位置が飛んで困る体験が複数回あったら → スクロール位置保持
- 検索が grep だと体感で耐えられなくなったら → ripgrep（その前に P1-3 の streaming/early-stop で様子見）

---

## Phase 2 で後段に倒した小項目（要件記載）

| Pri | 項目 | 関連 step | 工数感 |
|---|---|---|---|
| 🟡 | Cmd+P で Cmd+C パスコピー | step10 | 小 |
| 🟡 | Cmd+Shift+F の結果から該当行へジャンプ | step11 | 中（プレビュー側で行番号スクロールが必要） |
| 🟡 | Cmd+Shift+F で Cmd+C パスコピー | step11 | 小 |

---

## Phase 3 候補（要件 4 / 5 / 8 など）

> 要件 5 系（AI 連携）はいずれも要件に記載があるが、ターミナルペインで Claude Code をそのまま使えている現状では作り込む動機が薄い。`/handoff` `/plot` 等は Claude Code 側のスキルでカバーできている。**「これがないと不便」と実際に感じてから**着手する。

| Pri | 項目 | 一言 |
|---|---|---|
| 🟢 | AI 起動ショートカット（Cmd+Shift+T） | 要件 5。具体的な必要が出るまで保留 |
| 🟢 | カスタム起動テンプレート | 要件 5。具体的な必要が出るまで保留 |
| 🟢 | プロンプトテンプレートのワンタッチ挿入 | 要件 5。具体的な必要が出るまで保留 |
| 🟢 | プランファイル連携 | 要件 5。具体的な必要が出るまで保留 |
| 🟢 | AI ヘルス監視（claude が応答しない検知等） | 要件 5。具体的な必要が出るまで保留 |
| 🟢 | クロスエージェント引き継ぎ補助 | 要件 5。`/handoff` スキルで足りているなら不要 |
| 🟢 | AI 完了通知の精度向上 | 完了検知は `OSC 9;4` プログレス（作業中→REMOVE）ベースで実装済み（claude/codex はベルを鳴らさないため）。残: ツール呼び出しで途中 REMOVE が挟まる場合の debounce / 手動クリア / codex でも同じプログレスが来るかの確認。誤検知でうるさい体験が出たら debounce だけやる |

---

## 既知の課題・技術負債

対応する価値があるもの:

| Pri | 項目 | 対応案 |
|---|---|---|
| 🟡 | `PocLog`（`/tmp/ide-poc.log`）と `Logger`（`~/Library/Logs/ide/`）が並走している（stderr に二重出力） | `PocLog.write` の call site を `Logger.shared.debug` に置換して一本化。`SIMPLIFICATION_OPPORTUNITIES.md` P1-5 にも記載。`Logger` は十分安定しているので着手可 |
| 🟢 | ファイルツリーの「ターミナルで開く」が現状 pasteboard コピーだけ（しかもパスが shell エスケープされていない） | `SIMPLIFICATION_OPPORTUNITIES.md` P1-8 参照。短期は `shellEscape` 流用、中期は active surface に `cd -- <path>\n` を直接送る。そもそもこのメニューをほぼ使わないなら放置でも可 |

注意書き（対応済み or これ以上やることなし。記録として残す）:

| 項目 | 状況 |
|---|---|
| `IDE_TEST_*` 環境変数が複数（`AUTO_ACTIVATE_INDEX` `AUTO_PREVIEW` `AUTO_FULLSEARCH` `TOAST`） | docs/DEV.md にまとめてある。今後増やすなら命名規約を `IDE_TEST_<feature>_<param>` に統一する、という指針だけ。今すぐ何かする話ではない |
| SwiftUI の `onTapGesture` が AppleScript の `click at` に届かない | 動作確認は `IDE_TEST_*` で迂回済み。完全自動化は難しいので手動確認を VERIFY.md に残す方針で確定 |
| HSplitView は `idealWidth` を尊重しない | maxWidth で抑える workaround 済み（step1）。これ以上やることなし |

---

## 見送った項目（記録用）

- **セッション復元（active project / ツリー展開 / プレビュー履歴）** — 要件 2 / 7 が「再起動時はリセット」と明示しているので現設計と逆方向。方針を変えるなら再検討するが、当面はやらない。

---

## dogfooding で気付いたこと

dogfooding を進めながら追記する。日付は `YYYY-MM-DD` 形式（相対日付は使わない）。

---

## 更新ルール

- Phase 2.5 を切り出すタイミングで上の Phase 2.5 セクションを `docs/plans/phase2.5-*.md` の plan に昇格させる
- 解決した項目は ⚪ に変えてから次回コミットでまとめて削除する（記録は git log に残るので二重には残さない）
- アイデアレベルの追加は 🟢 で気軽に追記する
