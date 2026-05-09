# CLAUDE.md

このリポジトリで Claude Code が開発を続けるためのガイド。`~/.claude/CLAUDE.md`（グローバル）と併せて読まれる。

ユーザーから明示の指示がない限り、ここに書いてあるルールが優先する。

---

## このプロジェクトは何か

**ide**: cmux + Ghostty + yazi + git-watch + Claude Code を 1 つに統合した自作 IDE（macOS 専用）。

要件は [REQUIREMENTS.md](./REQUIREMENTS.md)。実装の進捗とアーキ概要は:

- 概要: [README.md](./README.md)
- モジュール構成: [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)
- 開発手順: [docs/DEV.md](./docs/DEV.md)
- 動作確認: [VERIFY.md](./VERIFY.md)
- 残タスク: [docs/BACKLOG.md](./docs/BACKLOG.md)

---

## 何かを始める前に必ず読む

1. **要件と整合する変更か** — `REQUIREMENTS.md` のセクション番号で議論する
2. **plan があるか** — `docs/plans/` の進行中 plan があれば、ステップ通りに進める
3. **テスト用フラグの位置** — `IDE_TEST_*` 環境変数の一覧は `docs/DEV.md`

---

## ビルドと動作確認

詳細は [docs/DEV.md](./docs/DEV.md)。最低限:

```bash
mise run build                                   # ビルド（regen を含む）
./scripts/ide-launch.sh                          # 起動（kill + open）
./scripts/ide-screenshot.sh /tmp/v.png           # フロントウィンドウだけ撮影
./scripts/ide-keystroke.sh --enter "echo hello"  # キーストローク送信
```

確認手順は [VERIFY.md](./VERIFY.md) の番号付きセクションを「変更内容に関係するものだけ」実行する（毎回全部やらない）。

---

## 動作確認は手抜きしない

修正後にユーザーへ確認を求める前に、自分で動作確認を行うこと。

- **コードの確認**: `mise run build` が通る
- **UI の確認**: `./scripts/ide-launch.sh` + `./scripts/ide-screenshot.sh` で画面を取って自分で確認する
- **テスト用フラグを活用**: `IDE_TEST_AUTO_ACTIVATE_INDEX` `IDE_TEST_AUTO_PREVIEW` `IDE_TEST_AUTO_FULLSEARCH` `IDE_TEST_TOAST` で起動時に状態を仕込んで screenshot 取得まで自動化できる

「確認しました」だけで済ませず、実行コマンド・出力（抜粋）・pass/fail 判定を報告する。

### ⚠️ projects.json は実ユーザーデータ。検証で破壊しない

`~/Library/Application Support/ide/projects.json` には**ユーザーが手で pin したプロジェクト一覧**が入っている。VERIFY.md の検証手順は固定フィクスチャで上書き → `rm -f` する流れが多いので、**検証前に必ずバックアップ**を取り、**検証後に復元**する:

```bash
# 検証開始前
BACKUP_DIR=$(mktemp -d)
cp -a "$HOME/Library/Application Support/ide/" "$BACKUP_DIR/ide-backup" 2>/dev/null || true

# 検証完了後
rm -rf "$HOME/Library/Application Support/ide"
mv "$BACKUP_DIR/ide-backup" "$HOME/Library/Application Support/ide" 2>/dev/null || true
```

過去にこの保護を怠ってユーザーのピン留めを全消ししたインシデントあり（2026-05-09）。

---

## SwiftUI / Swift 6 の落とし穴（既出）

[docs/DEV.md の同セクション](./docs/DEV.md#swift-6-strict-concurrency-の落とし穴) にまとまっている。**新しく踏んだら追記する**。

代表例:
- AppleScript の `click at {x, y}` は SwiftUI の `onTapGesture` に届かないことがある → `IDE_TEST_*` で迂回
- `Ctrl+M` の判定は `keyCode == 46`（characters は CR にマップされる）
- `URL` の `==` は scheme/baseURL の差で一致しないことがある → `URL.standardizedFileURL.path` を String キーに

---

## ログの使い分け

- **`PocLog.write(...)`**: デバッグ用、`/tmp/ide-poc.log`。`tail -f` で追えるので調査時に強い
- **`Logger.shared.{error|warn|info|debug}(...)`**: 永続ログ、`~/Library/Logs/ide/`
- 現在 `PocLog.write` 内部で `Logger.debug` にも転送している。Phase 2.5 で `PocLog` を撤去予定

エラー toast を出したいときは `ErrorBus.shared.notify(_:kind:)`。継続的な状態異常は各 View 内に常駐表示する（要件 8.3）。

---

## キー入力の優先順位

[docs/ARCHITECTURE.md の同セクション](./docs/ARCHITECTURE.md#キー入力の優先順位) を参照。

要点だけ:
- `NSEvent.addLocalMonitorForEvents`（`MRUKeyMonitor`）が最優先で、vim/claude 等の TUI 内でも握る
- Ctrl+M / Cmd+P / Cmd+Shift+F は IDE 側で必ず握り切る（要件 3「逃がし手段なし」）

---

## 計画と実装の進め方

新しい大きなタスクのときは:

1. `/dig`（または `/dig-lite`）で深掘り → `/plot` で `docs/plans/<name>.md` を作る
2. plan のステップ通りに進める。各ステップ完了でコミット
3. ログセクションに方針変更や想定外の失敗を 1 件 10 行以内で追記
4. 完了したら `/retro` で振り返りを提案

軽微な fix なら plan は不要。BACKLOG → 直接 fix → コミット で OK。

---

## ドキュメントの責務マップ

| ファイル | 責務 |
|---|---|
| `README.md` | プロジェクトの入口（30 秒で何ができるか分かる） |
| `REQUIREMENTS.md` | 要件（仕様の正） |
| `VERIFY.md` | 動作確認手順（自動 + 手動） |
| `CLAUDE.md` | ← 本文書。AI 向けの「これだけ読めば動ける」 |
| `docs/ARCHITECTURE.md` | モジュール構成・データフロー |
| `docs/DEV.md` | 開発時の手順・落とし穴 |
| `docs/BACKLOG.md` | 残タスク・Phase 2.5・Phase 3 アイデア |
| `docs/plans/*.md` | フェーズ単位の実装計画 |

新しい知見が出たら適切な場所に書き戻す。`docs/plans/` のログにも方針変更は残す。

---

## してはいけないこと

- `~/.claude/CLAUDE.md` のグローバルルール（Brew 管理、dotfiles 配置、mise タスク等）に違反する変更
- ユーザーの明示許可なしに、`git push --force` / `git reset --hard` 等の破壊的操作
- ユーザーの明示許可なしに、PR 作成 / push / 外部サービスへの投稿
- 動作確認なしに「実装完了」と報告
