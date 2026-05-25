# CLAUDE.md

このリポジトリで Claude Code が開発を続けるためのガイド。`~/.claude/CLAUDE.md`（グローバル）と併せて読まれる。

ユーザーから明示の指示がない限り、ここに書いてあるルールが優先する。

---

## このプロジェクトは何か

**PolePole**: cmux + Ghostty + yazi + git-watch + Claude Code を 1 つに統合した自作 IDE（macOS 専用）。
2026-05-23 にプロジェクト名を `ide` から `PolePole` にリネーム済み。技術文脈は小文字 `polepole`、ブランド表記は CamelCase `PolePole`。リポジトリ名は歴史的事情で `nyshk97/ide` のまま。

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
3. **テスト用フラグの位置** — `POLEPOLE_TEST_*` 環境変数の一覧は `docs/DEV.md`

---

## ビルドと動作確認

詳細は [docs/DEV.md](./docs/DEV.md)。最低限:

```bash
mise run build                                        # ビルド（regen を含む）
./scripts/polepole-launch.sh                          # 起動（kill + open）
./scripts/polepole-screenshot.sh /tmp/v.png           # フロントウィンドウだけ撮影
./scripts/polepole-keystroke.sh --enter "echo hello"  # キーストローク送信
```

確認手順は [VERIFY.md](./VERIFY.md) の番号付きセクションを「変更内容に関係するものだけ」実行する（毎回全部やらない）。

---

## 動作確認は手抜きしない

修正後にユーザーへ確認を求める前に、自分で動作確認を行うこと。

- **コードの確認**: `mise run build` が通る
- **UI の確認**: `./scripts/polepole-launch.sh` + `./scripts/polepole-screenshot.sh` で画面を取って自分で確認する
- **テスト用フラグを活用**: `POLEPOLE_TEST_AUTO_ACTIVATE_INDEX` `POLEPOLE_TEST_AUTO_PREVIEW` `POLEPOLE_TEST_AUTO_FULLSEARCH` `POLEPOLE_TEST_TOAST` で起動時に状態を仕込んで screenshot 取得まで自動化できる
- **クリック / キーストロークが要る検証は PolePole 内 Claude Code からは自動化できない**: `polepole-screenshot.sh`（画面収録）は OK だが、`polepole-keystroke.sh` 系（osascript の補助アクセス）は `login` 介在で効かない。「読み込む」ボタン押下後の挙動・Markdown のローカルリンククリック・overlay 上の Cmd+C などはユーザーに目視依頼する
- **Dock 検証では Release/Dev の取り違いに注意**: Brew 版 (`PolePole`) と Debug 版 (`PolePole Dev`) が両方 Dock にあるとき、AppleScript で `UI elements whose name contains "PolePole"` を使うと両方マッチして取り違える。Dev 版だけ欲しいときは `name is "PolePole Dev"` で完全一致させる。同様に `screencapture -R<x,y,w,h>` で Dock アイコン領域を撮る場合も、位置を取り違えると「Dev 側を変更したのに古い」と誤判定する

「確認しました」だけで済ませず、実行コマンド・出力（抜粋）・pass/fail 判定を報告する。

### ⚠️ PolePole の中で検証するには PolePole.app に TCC 権限が要る

`polepole-screenshot.sh` / `polepole-launch.sh` を PolePole 内ターミナルの Claude Code から回すには、`/Applications/PolePole.app` に **画面収録** と **フルディスクアクセス**（`~/Library/CloudStorage/` 配下の dotfiles を読むため）が付与されている必要がある。剥がれていると「could not create image from display」「`.zshrc` が読めずデフォルトプロンプト・mise/`claude` が PATH に無い」になる。Release ビルドは安定した Developer ID 署名なので brew 更新では剥がれない。詳細・再付与手順は [docs/DEV.md の「TCC（プライバシー）権限の罠」](./docs/DEV.md#tccプライバシー権限の罠)。

`ide` → `PolePole` リネーム時は Bundle ID が変わるため、旧 IDE.app に付与していた TCC 権限は新 PolePole.app には引き継がれない。初回は System Settings から手動で再付与する。

### ⚠️ Brew 版データ (`polepole/`) は触らない。検証は `polepole-dev/` で

`~/Library/Application Support/polepole/projects.json` には**Brew 配布版 (Bundle ID `local.d0ne1s.polepole`) でユーザーが手で pin したプロジェクト一覧**が入っている。Debug ビルドは Bundle ID が `local.d0ne1s.polepole.dev` に分離されているので、`mise run build` → `./scripts/polepole-launch.sh` 由来の起動・検証では `~/Library/Application Support/polepole-dev/projects.json` 側に書かれ、Brew 版データには触らない。

VERIFY.md の検証手順は固定フィクスチャで `polepole-dev/projects.json` を上書きする → `rm -f` する流れなので、Dev 版でもピン留めを残したい運用なら念のためバックアップ:

```bash
# 検証開始前
BACKUP_DIR=$(mktemp -d)
cp -a "$HOME/Library/Application Support/polepole-dev/" "$BACKUP_DIR/polepole-dev-backup" 2>/dev/null || true

# 検証完了後
rm -rf "$HOME/Library/Application Support/polepole-dev"
mv "$BACKUP_DIR/polepole-dev-backup" "$HOME/Library/Application Support/polepole-dev" 2>/dev/null || true
```

**Release configuration を直接起動して検証するときは `polepole/` 側を扱うことになる**ので、その経路では引き続き `polepole/` を退避してから検証する。

過去に Bundle ID 分離前のビルドで旧 `ide/` を破壊したインシデントあり（2026-05-09）。分離後はこの経路は塞がっているが、Release 検証時の警告は変わらず有効。

---

## SwiftUI / Swift 6 の落とし穴（既出）

[docs/DEV.md の同セクション](./docs/DEV.md#swift-6-strict-concurrency-の落とし穴) にまとまっている。**新しく踏んだら追記する**。

代表例:
- AppleScript の `click at {x, y}` は SwiftUI の `onTapGesture` に届かないことがある → `POLEPOLE_TEST_*` で迂回
- `Ctrl+M` の判定は `keyCode == 46`（characters は CR にマップされる）
- `URL` の `==` は scheme/baseURL の差で一致しないことがある → `URL.standardizedFileURL.path` を String キーに
- Debug ビルドは PRODUCT_NAME=`PolePole Dev` なので `.app` / プロセス / バイナリすべてに空白を含む。動作確認スクリプトでは `pkill -x "PolePole Dev"` / `pgrep -f "PolePole Dev.app/Contents/MacOS/PolePole Dev"` / AppleScript の `tell process "PolePole Dev"` のように毎回クオートする

---

## ログの使い分け

- **`Logger.shared.{error|warn|info|debug}(...)`**: 唯一のログ経路。永続ログは `~/Library/Logs/{polepole,polepole-dev}/`、加えて stderr に出力する
- **Debug ビルドのみ** `/tmp/polepole-poc.log` にもミラーする（`tail -f` で追える、VERIFY 用）。起動時に `Logger.shared.resetDebugMirror()` で空にする
- 旧 `PocLog` は撤去済み（call site はすべて `Logger.shared.debug` に置換）

エラー toast を出したいときは `ErrorBus.shared.notify(_:kind:)`。継続的な状態異常は各 View 内に常駐表示する（要件 8.3）。

---

## アプリのデータパスは `AppPaths.subdirName` 経由で参照する

`~/Library/Application Support/`、`~/Library/Logs/`、将来追加する Preferences / cache / state 等のサブディレクトリ名は `"polepole"` をハードコードせず `AppPaths.subdirName` を経由する（`ProjectsStore` / `Logger` が参考）。Debug ビルドは Bundle ID `local.d0ne1s.polepole.dev` を見て自動的に `polepole-dev/` に振り分けられる。これを忘れると Brew 配布版データを上書きする経路が復活する。

---

## キー入力の優先順位

[docs/ARCHITECTURE.md の同セクション](./docs/ARCHITECTURE.md#キー入力の優先順位) を参照。

要点だけ:
- `NSEvent.addLocalMonitorForEvents`（`MRUKeyMonitor`）が最優先で、vim/claude 等の TUI 内でも握る
- Ctrl+M / Cmd+P / Cmd+Shift+F は PolePole 側で必ず握り切る（要件 3「逃がし手段なし」）

---

## ショートカット追加時の更新箇所

ショートカットの実装場所は次の 2 種類で、追加する場所によって付随する更新が変わる。

- **リバインド可能にする**: `ShortcutAction` に case を足し、`ShortcutAction.defaults` に初期値を入れ、MRUKeyMonitor（または対応する場所）で `ShortcutsStore.shared.matches(event, .xxx)` 経由で発火させる。設定画面 (`ShortcutsSettingsView`) の表示は自動で乗る
- **固定で実装する**: MRUKeyMonitor / SwiftUI .keyboardShortcut / Ghostty performKeyEquivalent のいずれかで直書きする。同時に `ShortcutsStore.swift` 末尾の `FixedShortcuts.all` に 1 行足す — これを忘れると Settings 画面の衝突警告が抜けて、ユーザーが既存固定キーと同じ組み合わせに気付かないまま割り当てられる

MRU の確定タイミング（修飾キーの release）は `ShortcutsStore.shouldCommitMRU` 経由なので、`.mruOverlay` のバインドをリバインドしても自動で追随する。

---

## リリースノート (CHANGELOG)

ユーザー目視で気づくレベルの変更は `docs/CHANGELOG.md` の `[Unreleased]` セクションに残す。基本は **リリース時** に AI が `release.sh` の pause 中に git log を見て一括で書く運用なので、日々のコミットでは追記しなくて良い。

書く形式:

```markdown
### ✨ Added
- ja: 機能 A を追加
- en: Added feature A
```

- 各項目は **必ず `- ja:` と `- en:` のペア** で書く（`backend/scripts/build-changelog.mjs` が prefix で振り分けて `/changelog` と `/en/changelog` を生成する）
- カテゴリは `✨ Added` / `📝 Changed` / `🐛 Fixed` / `🗑️ Removed` / `🔒 Security` / `⚠️ Deprecated` から選ぶ
- 内部リファクタ / docs-only / CI 調整は **書かない**
- 詳しい運用は [docs/CHANGELOG.md](./docs/CHANGELOG.md) の冒頭 "書き方" セクション参照

`scripts/release.sh <version>` が走ると以下が自動で起きる:

1. 直近 commit を表示して pause → AI/人間が `[Unreleased]` を埋める
2. `[Unreleased]` → `[<version>] - <date>` にリネーム + commit
3. 該当 section を抜き出して GitHub Release notes (md, ja/en 両方) と Sparkle appcast の `<description>` (HTML, ja のみ) を生成
4. build → notarize → staple → zip
5. `git push origin main`（**release.sh が内部で実施するので事前 push は不要**）
6. EdDSA 署名 → appcast.xml 生成 → `nyshk97/polepole-releases` に GitHub Release 作成

`[Unreleased]` を事前に埋めておけば、`echo "" | bash scripts/release.sh <version>` で pause を即抜けて非対話で回せる（CHANGELOG 編集は AI が事前に済ませる前提）。**事前に `project.yml` の `MARKETING_VERSION` を bump してコミット**しておく必要がある（release.sh は project.yml をいじらない）。

**release.sh が終わったあとの手動作業**: Homebrew cask (`nyshk97/homebrew-tap/Casks/polepole.rb`) の `version` / `sha256` 更新。release.sh 末尾の出力をそのまま `version "X.Y.Z"` / `sha256 "..."` に貼って、別 repo を clone → 編集 → commit `"polepole X.Y.Z"` → push する（`brew upgrade --cask polepole` の更新元なので、ここを忘れると Homebrew ユーザーは古いままになる）。

公式サイトの `/changelog` `/en/changelog` は `pnpm build:changelog` (= `node backend/scripts/build-changelog.mjs`) で再生成する。`wrangler deploy` の `predeploy` フックに入っているので、デプロイすれば自動で最新になる。

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
| `docs/BACKLOG.md` | 残タスク・将来アイデア（優先度別） |
| `docs/COMMERCIALIZATION.md` | 商用化（有償配布）に向けた MUST / SHOULD / NICE とオープン論点 |
| `docs/CHANGELOG.md` | リリースノートの source-of-truth（Keep a Changelog 形式、ja/en 並列）。公式サイト `/changelog` `/en/changelog` と Sparkle appcast description / GitHub Release notes の元になる |
| `docs/plans/*.md` | フェーズ単位の実装計画（PolePole リネーム前の `ide` 名義の plan も歴史保存） |

新しい知見が出たら適切な場所に書き戻す。`docs/plans/` のログにも方針変更は残す。

---

## してはいけないこと

- `~/.claude/CLAUDE.md` のグローバルルール（Brew 管理、dotfiles 配置、mise タスク等）に違反する変更
- ユーザーの明示許可なしに、`git push --force` / `git reset --hard` 等の破壊的操作
- ユーザーの明示許可なしに、PR 作成 / push / 外部サービスへの投稿
- 動作確認なしに「実装完了」と報告
