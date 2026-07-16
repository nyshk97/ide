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
- **Debug 版へ `POLEPOLE_TEST_*` を渡す UI 検証は `open -n "$APP" --env KEY=value` を優先**: PolePole Release 内の Claude/Codex から Debug binary を直叩きすると、親プロセスの `GHOSTTY_RESOURCES_DIR` などを継承して Release 側 resource を参照し、window / screenshot 検証が不安定になることがある。環境変数依存そのものを検証したい場合だけ binary 直叩きを使う
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
- `NSViewControllerRepresentable` を別の `NSViewControllerRepresentable` の中にネストするとクラッシュする（SwiftUI の VC 親子ツリーが壊れる）。複数ペインを AppKit で組み合わせるときは単一の `NSViewController` サブクラスの中で直接 `NSSplitView` を管理する

---

## libghostty (Metal renderer) の制約

`ghostty_surface_new` で渡した `cfg.platform.macos.nsview` を libghostty が**内部で握り続ける**。`ghostty_surface_set_*` には nsview 差し替え API が無い。`addSubview` で reparent しても新 superlayer に Metal binding が再束縛されず、移動後のタブが真っ黒になる (Phase 3 で踏んだ)。

surface を抱える NSView (`GhosttyTerminalNSView`) は **lifetime を通じて同じ superview に固定**し、見た目を動かしたい場合は `TerminalsHostView` + `TerminalAnchorView` の **portal host + anchor 追従パターン**を使う:

- `WorkspaceModel.terminalsHost` が window root 付近の固定 NSView 配下で全 tab の `realNSView` を抱える
- SwiftUI tree には透明な `AnchorNSView` を置き、自身の frame を host 座標系に変換 (`convert(bounds, to: host)`) して host に通知
- host が `tab.realNSView.frame` を anchor 位置に追従させる
- ペイン跨ぎ移動 = `pane.tabs` 配列の操作だけ。`realNSView` の親 (host) は不変

closeTab で `terminalsHost.detach(realNSView)` + `releaseSurface()` を **必ず即時実行する**こと。host は subview を強参照するため、忘れると閉じたタブの view が画面に残る / surface free が遅延する / firstResponder が宙に浮く。

cmux 実装も同じ理解 (`.refs/cmux/Sources/GhosttyTerminalView.swift` 参照)。

---

## ログの使い分け

- **`Logger.shared.{error|warn|info|debug}(...)`**: 唯一のログ経路。永続ログは `~/Library/Logs/{polepole,polepole-dev}/`、加えて stderr に出力する
- **Debug ビルドのみ** `/tmp/polepole-poc.log` にもミラーする（`tail -f` で追える、VERIFY 用）。起動時に `Logger.shared.resetDebugMirror()` で空にする
- 旧 `PocLog` は撤去済み（call site はすべて `Logger.shared.debug` に置換）

エラー toast を出したいときは `ErrorBus.shared.notify(_:kind:)`。継続的な状態異常は各 View 内に常駐表示する（要件 8.3）。

git 系機能全般（ツリー/バッジ/Cmd+P/Cmd+Shift+F/Cmd+D）が「遅い・固まる」という報告は、まず `grep -c "drain timed out" ~/Library/Logs/polepole/polepole-*.log` を確認する。件数が多ければ外部コマンド実行基盤の劣化（VERIFY.md §21.5 参照）で、個別機能のバグではない。

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

## Git repository boundary の扱い

Cmd+P / Cmd+Shift+F / Cmd+D diff / diff badge など workspace 横断で Git repository boundary を扱う機能は `GitRepositoryDiscovery` を single source of truth にする。探索対象は active project root と直下 child repository のみで、再帰探索しない。親 repository 側の status / diff / file index / full-text search から child repository 配下を除外するときは `rel == childRel || rel.hasPrefix(childRel + "/")` に揃える。child repository 内は child repository 自身の `.gitignore` / status / diff を使う。active project root が非 Git でも、親直下の通常ファイルや non-repo directory は remainder として検索対象に残す。

---

## AI 完了通知の発火経路と落とし穴

通知系の不具合（友達/他人の環境で「通知が出ない」）が来たときは、次の経路のどこで止まっているかを切り分ける:

1. **Claude/Codex が `OSC 9;4` progress を吐く**（INDETERMINATE/SET → REMOVE）
2. libghostty が `GHOSTTY_ACTION_PROGRESS_REPORT` を発火 (`GhosttyManager.swift:271-299`)
3. `tab.foregroundProgram` が `.claude` または `.codex` であること（`ForegroundProcessInspector.classify()`）
4. `aiTurnInProgress == true` での REMOVE 受信 → `playNotificationSound()` + `markUnreadIfBackgrounded()`
5. アクティブタブで完了 → 赤丸は出さない（仕様）/ 非アクティブのみ赤丸点灯

### 典型的に外れるポイント

- **classify() が `.other("node")` を返す**: npm 経由でグローバルインストールした claude は `node /path/to/cli.js` として起動するため、p_comm が `node` になる。**fix**: `node`/`bun`/`deno`/`python` 等の汎用 interpreter のときは `procArgs(for:)`（`KERN_PROCARGS2`）で argv を取り、`@anthropic-ai/claude-code` 等の文字列で識別する（`ForegroundProcessInspector.swift` で実装済み）
- **Claude/Codex が古くて OSC 9;4 を出していない**: 友達の AI ツールが古いだけ。最新版を入れてもらう
- **アクティブタブで完了したから赤丸が出ない**: 仕様。サウンドだけ鳴る

### 切り分けコマンド

```bash
# 友達のログから検知の経路を追う
grep -E "\[fg\]|\[progress\]|\[unread\]" ~/Library/Logs/polepole/polepole-*.log | tail -50

# fg=other(node) が出ていたら、友達の claude が npm wrapper の可能性
file "$(which claude)" && head -1 "$(which claude)"
```

`[fg]` 行は Debug ビルドだけ出る (`#if DEBUG`、`GhosttyManager.swift:123-128`)。Release で困ったら Diagnostics 画面が欲しくなる（BACKLOG）。

ユーザー向けの guide は `/guide#ai-notifications` (`backend/public/guide.html`) を参照させる。

---

## ショートカット追加時の更新箇所

ショートカットの実装場所は次の 2 種類で、追加する場所によって付随する更新が変わる。

- **リバインド可能にする**: `ShortcutAction` に case を足し、`ShortcutAction.defaults` に初期値を入れ、MRUKeyMonitor（または対応する場所）で `ShortcutsStore.shared.matches(event, .xxx)` 経由で発火させる。設定画面 (`ShortcutsSettingsView`) の表示は自動で乗る
- **固定で実装する**: MRUKeyMonitor / SwiftUI .keyboardShortcut / Ghostty performKeyEquivalent のいずれかで直書きする。同時に `ShortcutsStore.swift` 末尾の `FixedShortcuts.all` に 1 行足す — これを忘れると Settings 画面の衝突警告が抜けて、ユーザーが既存固定キーと同じ組み合わせに気付かないまま割り当てられる

MRU の確定タイミング（修飾キーの release）は `ShortcutsStore.shouldCommitMRU` 経由なので、`.mruOverlay` のバインドをリバインドしても自動で追随する。

`MRUKeyMonitor.handleKeyDown` 冒頭の `if shortcuts.isRecordingShortcut { return false }` は**必ず維持**する。これを抜くと、Settings 画面で既存ショートカット (Cmd+P / Cmd+T 等) を録音しようとした瞬間にプロセスレベルの `addLocalMonitorForEvents` が先勝ちで握って実動作してしまい、衝突警告が出ない。新規ハンドラを追加するときも、この素通り条件より下に置く前提で書く。

---

## リリースノート (CHANGELOG)

ユーザー目視で気づくレベルの変更は `docs/CHANGELOG.md` の `[Unreleased]` セクションに残す。基本は **リリース時** に AI が `release.sh` の pause 中に `git log` + `git diff` を見て一括で書く運用なので、日々のコミットでは追記しなくて良い。

**書き方の本体は [docs/CHANGELOG.md](./docs/CHANGELOG.md) 冒頭の「書き方」セクションに集約**してある。AI が自動生成するときはあそこだけ読めば自走できるレベルに整備済み (フォーマット制約・カテゴリ判定・ja/en の文体・粒度・書く / 書かない・自動生成チェックリスト)。

キーポイントだけ:

- **ペア**: 各項目は `- ja:` と `- en:` の 2 行を隣接させる (build script が prefix で振り分けて `/changelog` `/en/changelog` を生成)
- **1 項目 = 1 行**: build script は単一行の `- ja:` / `- en:` しか拾わない。改行・継続行は捨てられる
- **文体**: ja = 体言止め基調 (`〜を追加` / `〜を修正` / `〜に変更`)、en = ユーザー視点の現在形 / 単純過去
- **書かない**: 内部リファクタ / docs-only / CI / version bump 自体 / 内部ログ調整 / 依存 bump
- **粒度**: 1 リリース 1〜5 bullet が目安。同じ機能の連続 commit は 1 bullet にまとめる

`scripts/release.sh <version>` が走ると以下が自動で起きる:

1. 直近 commit を表示して pause → AI/人間が `[Unreleased]` を埋める
2. `[Unreleased]` → `[<version>] - <date>` にリネーム + commit
3. 該当 section を抜き出して GitHub Release notes (md, ja/en 両方) と Sparkle appcast の `<description>` (HTML, ja のみ) を生成
4. build → notarize → staple → zip
5. `git push origin main`（**release.sh が内部で実施するので事前 push は不要**）
6. EdDSA 署名 → appcast.xml 生成 → `nyshk97/polepole-releases` に GitHub Release 作成

`[Unreleased]` を事前に埋めておけば、`echo "" | bash scripts/release.sh <version>` で pause を即抜けて非対話で回せる（CHANGELOG 編集は AI が事前に済ませる前提）。**事前に `project.yml` の `MARKETING_VERSION` を bump してコミット**しておく必要がある（release.sh は project.yml をいじらない）。

⚠️ **非対話実行時の落とし穴**: `[Unreleased]` セクションを埋めるとき、**`[Unreleased]` ヘッダー自体を `[x.y.z]` に書き換えてはいけない**。release.sh が同名ヘッダーを重複挿入し、最初の空ヘッダーから内容を抽出するため Sparkle description が空になる。`[Unreleased]` ヘッダーはそのままにして、その下にコンテンツだけ書いてコミットする。

**release.sh が終わったあとの手動作業**: Homebrew cask (`nyshk97/homebrew-tap/Casks/polepole.rb`) の `version` / `sha256` 更新。release.sh 末尾の出力をそのまま `version "X.Y.Z"` / `sha256 "..."` に貼って、別 repo を clone → 編集 → commit `"polepole X.Y.Z"` → push する（`brew upgrade --cask polepole` の更新元なので、ここを忘れると Homebrew ユーザーは古いままになる）。

cask は `/opt/homebrew/Library/Taps/nyshk97/homebrew-tap/` にある (`brew --repository nyshk97/tap` で取れる)。**push 順序**: brew tap 更新で remote が先行している可能性があるので **commit → `pull --rebase origin main` → push** の順で。`pull --rebase` は dirty tree だと拒否されるので必ず commit が先。conflict が出たら新版 (1.4.X) を採用して `git add` → `git rebase --continue` → push。

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
