# ide

自分専用 IDE。**cmux + Ghostty + yazi + git-watch + Claude Code** を 1 つに統合した macOS 専用アプリ。

PoC 段階。要件は [REQUIREMENTS.md](./REQUIREMENTS.md)。

> [!NOTE]
> このリポジトリは個人用ツール。配布・署名・自動更新・他ユーザー対応は考慮していない。

---

## できること（Phase 2 完了時点）

- ✅ **Ghostty 統合ターミナル** + 上下 2 ペイン × 複数タブ + IME + URL リンク化 + AI 種別バッジ + BEL 通知
- ✅ **プロジェクト管理** — ピン留め永続化 / 一時 / Ctrl+M MRU 切替 / missing 検知
- ✅ **ファイルツリー** — フォルダ先・アルファベット順 / `.gitignore` 薄表示 / git status バッジ（M/A/D/?）
- ✅ **ファイルプレビュー** — コード / Markdown / 画像 / PDF / バイナリ判定 / サイズしきい値 / 履歴ナビ / Cmd+Option+O で VSCode
- ✅ **Cmd+P クイック検索** — ファジーマッチ + recents 優先
- ✅ **Cmd+Shift+F 全文検索** — grep ベース（ripgrep バンドリングは Phase 2.5）
- ✅ **ログ** — `~/Library/Logs/ide/`（日次ローテーション）、Help > 最近のログを開く
- ✅ **エラー toast** — 単発エラー / 継続状態異常の使い分けポリシー

未実装は [docs/BACKLOG.md](./docs/BACKLOG.md)。

---

## セットアップ

### 必要なもの

- macOS 14+ / Apple Silicon
- Xcode（Swift 6 strict concurrency 対応）
- [mise](https://mise.jdx.dev/)（XcodeGen を引いてくる）

ホスト初回セットアップ手順は dotfiles 側 `Brewfile` 参照。

### ビルド

```bash
mise run build       # XcodeGen で project 再生成 → Debug ビルド
mise run run         # ビルド + 起動
./scripts/ide-launch.sh  # 既存プロセスを kill して起動だけ
```

ビルド成果物は `/tmp/ide-build/Build/Products/Debug/ide.app`。

### クリーン

```bash
mise run clean   # /tmp/ide-build と ide.xcodeproj を消す
```

---

## 開発を続ける

| ドキュメント | 用途 |
|---|---|
| [REQUIREMENTS.md](./REQUIREMENTS.md) | 要件（仕様の正） |
| [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) | モジュール構成・データフロー |
| [docs/DEV.md](./docs/DEV.md) | 開発時の手順・テスト用環境変数・落とし穴 |
| [VERIFY.md](./VERIFY.md) | 動作確認手順（自動・手動） |
| [docs/BACKLOG.md](./docs/BACKLOG.md) | 残タスク・Phase 2.5・Phase 3 アイデア |
| [docs/plans/](./docs/plans) | フェーズ単位の実装計画 |
| [CLAUDE.md](./CLAUDE.md) | Claude Code（AI）向けガイド |

---

## ステータス

- **Phase 1**: ターミナル基盤（Ghostty + 上下 2 ペイン + 複数タブ + IME + クリップボード + BEL + AI バッジ）✅ 完了
- **Phase 2**: プロジェクト管理 + ファイル系 UI（サイドバー / ツリー / プレビュー / 検索 / ログ / toast）✅ 完了
- **Phase 2.5**: FSEvents 統合 / プレビュー自動リロード / ripgrep バンドリング ⏳ 着手前（dogfooding 中）
- **Phase 3**: AI 関連機能（カスタム起動テンプレート / プランファイル連携 等）— 未計画

実装の進捗は `git log` か `docs/plans/*.md` 参照。
