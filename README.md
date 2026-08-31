# PolePole

ターミナルで動く AI コーディング CLI（Claude Code / Codex CLI など）を、複数プロジェクト並列で走らせるための macOS ワークスペース。cmux + Ghostty + yazi + git-watch を 1 つのアプリに統合した、**編集しない IDE** です。

![PolePole の画面](./docs/images/overview.png)

**[公式サイト](https://polepole.dev)** · **[ガイド](https://polepole.dev/guide)** · **[チェンジログ](https://polepole.dev/changelog)**

---

## コンセプト

コードを書くのは AI、人間はレビューと指示 — そうなってみると、必要なのは編集機能ではなく、**複数プロジェクト × 複数ターミナルを最短の手数で行き来して、AI の出力を確認する**ための道具でした。PolePole は閲覧 + ターミナル + プロジェクト管理に特化し、編集は各自のエディタに逃がします。特定の AI ツールに依存しない、ただのターミナルとして作ってあります。

画面は左から **プロジェクトサイドバー** / **ファイルツリー + プレビュー** / **Ghostty 統合ターミナル**（上下 2 ペイン × 複数タブ）の 3 カラム構成。

## 主な機能

- **libghostty 組み込みターミナル** — Ghostty と同じ Metal レンダラを SwiftUI の中に埋め込み
- **Ctrl+M プロジェクト切替** — MRU 順のオーバーレイ。vim や claude の TUI 中でも必ず効く
- **AI 完了通知** — Claude Code / Codex の進捗通知（OSC 9;4）を検知し、ターン完了でサウンド + 非アクティブタブに赤丸バッジ。タブには AI 種別バッジも出る
- **git ウォッチ** — ファイルツリーに status バッジ、Cmd+D で diff、Cmd+P ファイル名検索、Cmd+Shift+F 全文検索。子リポジトリの境界も正しく扱う
- **閲覧専用のファイルツリー + プレビュー** — Markdown レンダリング等。編集機能は意図的に持たない
- **ショートカットのカスタマイズ** — 主要ショートカットは設定画面で変更可能（既存キーとの衝突警告つき）

## ソースからビルド

```bash
mise run build                # XcodeGen で project 再生成 → Debug ビルド
mise run run                  # ビルド + 起動
./scripts/polepole-launch.sh  # 既存プロセスを kill して起動だけ
```

前提:

- macOS 14+ / Apple Silicon
- Xcode（Swift 6 strict concurrency が通るバージョン）
- [mise](https://mise.jdx.dev/)
- `GhosttyKit.xcframework` をプロジェクトルートに配置（リポジトリには含まれない。[Ghostty](https://github.com/ghostty-org/ghostty) のソースからビルドする。使用 commit は `GhosttyKit.xcframework/.ghostty_sha` に pin）

Debug ビルドは Bundle ID・表示名・データディレクトリが Release と分離されており（`PolePole Dev`）、常用版を壊さずに開発できます。詳細は [docs/DEV.md](./docs/DEV.md)。

## Highlights

- **libghostty の SwiftUI 統合** — libghostty は surface を渡した NSView を内部で握り続けるため、素朴に reparent すると Metal binding が壊れます。surface を持つ NSView は固定の host に置いたまま、SwiftUI ツリーには透明なアンカーだけを置いて frame を追従させる portal パターンで解決（[docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)）
- **AI の foreground 判別** — npm 経由の claude は p_comm が `node` になるため、`KERN_PROCARGS2` で argv を取って識別
- **Swift 6 strict concurrency** を全面採用。踏んだ罠は [docs/DEV.md](./docs/DEV.md) に蓄積

## ドキュメント

| ファイル | 用途 |
|---|---|
| [REQUIREMENTS.md](./REQUIREMENTS.md) | 要件（仕様の正） |
| [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) | モジュール構成・データフロー |
| [docs/DEV.md](./docs/DEV.md) | 開発手順・テスト用環境変数・落とし穴 |
| [VERIFY.md](./VERIFY.md) | 動作確認手順（自動 + 手動） |
| [docs/CHANGELOG.md](./docs/CHANGELOG.md) | リリースノート（ja/en） |
| [docs/BACKLOG.md](./docs/BACKLOG.md) | 残タスク・将来アイデア |
| [docs/plans/](./docs/plans) | フェーズ単位の実装計画 |
| [CLAUDE.md](./CLAUDE.md) | Claude Code（AI）向けの作業ガイド |

## 関連リポジトリ

- Sparkle 配信 + リリース: <https://github.com/nyshk97/polepole-releases>
- Homebrew tap: <https://github.com/nyshk97/homebrew-tap>

## ライセンス

[MIT](./LICENSE)
