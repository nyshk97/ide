# BACKLOG

Phase 2 完了時点（commit `c922a65`）で残っているタスクと、今後のアイデアを集約する場所。

ステータスを 4 段階で区別する:

- 🔴 **P0**: 要件にあって、UX 上ないと困る（dogfooding で気になる確度が高い）
- 🟡 **P1**: 要件にあるが、当面なくても回る（後段に倒した小項目）
- 🟢 **P2**: 要件には未記載 or アイデア段階
- ⚪ **解決済み**: 実装が入ったらここから消す

---

## Phase 2.5（持ち越しの大物）

| Pri | 項目 | 関連 step | 一言 |
|---|---|---|---|
| 🔴 | FSEvents によるファイルツリー差分反映 | step7 | 新規ファイル作成・削除がツリーに即時反映されるように |
| 🔴 | プレビュー自動リロード（行番号基準）+ deleted 表示 | step8 | 編集中ファイルが外部から変わったら追従 |
| 🟡 | ripgrep バンドリング | step11 | 現状 macOS 標準 grep で代用、entitlements 含めて検証必要 |

### Phase 2.5 着手の合図
- dogfooding でファイルツリー差分の手動 reload が頻繁に必要になったら → FSEvents を最優先
- プレビューを開いたまま vim で編集して「あれ反映されない」体験が複数回あったら → 自動リロード
- 検索性能が grep だと耐えられなくなったら → ripgrep

---

## Phase 2 で後段に倒した小項目（要件記載）

| Pri | 項目 | 関連 step | 工数感 |
|---|---|---|---|
| 🟡 | ピン留めプロジェクトのドラッグ並び替え | step3 | 小（SwiftUI `.onMove` 1 ヶ所） |
| 🟡 | Cmd+P で Cmd+C パスコピー | step10 | 小 |
| 🟡 | Cmd+Shift+F の結果から該当行へジャンプ | step11 | 中（プレビュー側で行番号スクロールが必要） |
| 🟡 | Cmd+Shift+F で Cmd+C パスコピー | step11 | 小 |

---

## Phase 3 候補（要件 4 / 5 / 8 など）

| Pri | 項目 | 一言 |
|---|---|---|
| 🟢 | AI 起動ショートカット（Cmd+Shift+T） | 要件 5 |
| 🟢 | カスタム起動テンプレート | 要件 5 |
| 🟢 | プロンプトテンプレートのワンタッチ挿入 | 要件 5 |
| 🟢 | プランファイル連携 | 要件 5 |
| 🟢 | AI ヘルス監視（claude が応答しない検知等） | 要件 5 |
| 🟢 | クロスエージェント引き継ぎ補助 | 要件 5 |
| 🟢 | コードプレビューのシンタックスハイライト | step8 で単純 NSTextView。Highlightr or tree-sitter |
| 🟢 | Markdown 完全レンダリング | 現状は `AttributedString` の inlineOnly |
| 🟢 | BEL 通知の誤検知対策 | Phase 1 の積み残し、誤検知が顕在化したら |
| 🟢 | セッション復元 | 要件未記載、運用見て判断 |

---

## 既知の課題・技術負債

| Pri | 項目 | 対応案 |
|---|---|---|
| 🟡 | `PocLog`（`/tmp/ide-poc.log`）と `Logger`（`~/Library/Logs/ide/`）が並走している | step12 で導入した `Logger` が安定したら `PocLog` を撤去、`Logger.debug` に一本化 |
| 🟡 | `IDE_TEST_*` 環境変数が複数（`AUTO_ACTIVATE_INDEX` `AUTO_PREVIEW` `AUTO_FULLSEARCH` `TOAST`） | docs/DEV.md にまとめてある。今後増やすなら命名規約を `IDE_TEST_<feature>_<param>` に統一 |
| 🟡 | SwiftUI の `onTapGesture` が AppleScript の `click at` に届かない | 動作確認は `IDE_TEST_*` で迂回。完全自動化は難しいので手動確認を VERIFY.md に残す方針 |
| 🟡 | HSplitView は `idealWidth` を尊重しない | step1 で maxWidth で抑える workaround |
| 🟢 | ファイルツリーの「ターミナルで開く」が現状 pasteboard コピーだけ | 本来は active surface に `cd <path>\n` を直接送りたい。`ghostty_surface_text` 等の API を要調査 |

---

## dogfooding で気付いたこと

dogfooding を進めながら追記する。

```
- 2026-MM-DD: …
```

---

## 更新ルール

- Phase 2.5 を切り出すタイミングで上の Phase 2.5 セクションを `docs/plans/phase2.5-*.md` の plan に昇格させる
- 解決した項目は ⚪ に変えてから次回コミットでまとめて削除する（記録は git log に残るので二重には残さない）
- アイデアレベルの追加は 🟢 で気軽に追記する
