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
| 起動時に「dotfiles / CloudStorage が読めない」を検出して案内する | `IDE.app` にフルディスクアクセスが無いと IDE 内シェルが `~/.zshrc`（→ `~/Library/CloudStorage/` の dotfiles）を `EPERM` で読めず、デフォルトプロンプト・mise 未起動・`claude` not found になる（[docs/DEV.md の TCC の節](./DEV.md#tccプライバシー権限の罠) 参照）。起動時に「`~/.zshrc` が読めない」or「`~/Library/CloudStorage/` にアクセスできない」を検出したら、要件 8.3 の常駐表示で「フルディスクアクセスを付与してください」+ System Settings（`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`）を開くボタンを出す。**次に同じ状況になったとき一発で気づける**ようにしたくなったら。同様に画面収録が無いときの案内も合わせられる |
| 検索 / ツリーの除外ポリシー一元化（整理パス P1-2） | `FileIndex` の `alwaysSkipDirNames`/`cheapSkipDirNames`（`.git` / `node_modules` / `DerivedData` / `.build`）と `FullTextSearcher` の `--exclude-dir`（+ `.refs`）がまだ別管理。`SearchPolicy` 的な enum に寄せると Cmd+P / Cmd+Shift+F / ツリーの挙動差分を見つけやすい。**ripgrep バンドリング（上の行）をやるときに一緒に**。単独でやる動機は薄い |
| `ProjectsModel` の責務分割 / foreground polling 間引き / ファイルツリーの node 探索の辞書化（整理パス P2-1〜P2-3） | いずれも現状困っていない。**`ProjectsModel` が肥大で触りづらくなったら**（list / workspace registry / search overlay / test bootstrap に分ける）/ **多タブで動作が重くなったら**（idle tab の foreground poll を 2-3 秒間隔に）/ **巨大ツリーの展開が遅いと感じたら**（`nodeByPath: [FilePathKey: FileNode]`） |
| Release entitlement 変更の実機検証（整理パス P1-7） | `Resources/IDE.entitlements` から `com.apple.security.automation.apple-events` を削除済み（残り 3 つの hardened runtime 例外は libghostty 由来で残置）。Release ビルド + notarize + 実機でターミナル描画 / IME / クリップボードが正常か確認する。低リスクなので単体でリリースを切らず、**次に何かの理由でリリースするタイミングに相乗り**。NG なら entitlement を戻す |

---

## 当面やらない（要件記載だが今は動機が薄い / 現設計と逆）

- **要件 5 系の AI 連携** — AI 起動ショートカット（Cmd+Shift+T）、カスタム起動テンプレート、プロンプトテンプレートのワンタッチ挿入、プランファイル連携、AI ヘルス監視（claude が応答しない検知）、クロスエージェント引き継ぎ補助。いずれも要件には記載があるが、ターミナルペインで Claude Code をそのまま使えている現状では IDE 側に作り込む動機が薄い。`/handoff` `/plot` 等は Claude Code 側のスキルでカバーできている。**「これがないと不便」と実際に感じたら**個別に上の表へ。
- **セッション復元（active project / ツリー展開 / プレビュー履歴）** — 要件 2 / 7 が「再起動時はリセット」と明示しているので現設計と逆方向。方針を変えるなら再検討。

---

## 商用化（有償配布）を見据えた検討項目

「外部ユーザーに有料で使ってもらう」段階に入ったらまとめて着手する。今は Sparkle で自前アップデート基盤だけ整えた状態（appcast は `nyshk97/ide-releases` の `latest/download/appcast.xml` を使う / 詳細は [docs/DEV.md](./DEV.md#sparkle-自前アップデート) と [docs/plans/2026-05-14-sparkle-auto-update.md](./plans/2026-05-14-sparkle-auto-update.md)）。

- **ライセンス検証 / アクティベーション** — 起動時に「メールアドレス + ライセンスキー」入力 → サーバーで検証 → ローカルに署名済みトークンを保存。Sparkle の `SUUpdaterDelegate` の `feedURLString(for:)` でユーザー毎に異なる appcast を返すこともできる（pro / beta チャネル分け）。サーバー側は最小なら Cloudflare Workers + D1 / KV で足りる。
- **トライアル期間** — 起動時に install date を Application Support に書いて、N 日経過後はメニューと一部機能を制限。
- **配信フィードの専用ドメイン化** — 今は `github.com/nyshk97/ide-releases/...` だが、いずれ `updates.<your-domain>/ide/appcast.xml` などにしたい。R2 + 独自ドメインへの移行は別途タスク。URL を変えるときは旧 SUFeedURL を踏むユーザーのために GitHub 側にも appcast を残しておく（リダイレクトが効かないので両方更新する運用）。
- **本体 ide repo の private 化** — 配信を `nyshk97/ide-releases` に集約してあるので、機能的には今すぐ private 化できる。ただ homebrew cask (`nyshk97/homebrew-tap`) は `nyshk97/ide` の release zip を参照しているので、cask URL を `ide-releases` に向け直してから private 化する。
- **EdDSA 秘密鍵紛失時のリカバリ** — Sparkle はパッケージ全体に新鍵で再署名するしか手段がない。旧版にいるユーザーは手動で新版 IDE.app を入れ直す必要がある。Dropbox バックアップ（`~/Library/CloudStorage/Dropbox/secrets/sparkle-ed25519-private.key`）を消さない運用ルールは [docs/DEV.md](./DEV.md#eddsa-鍵) に書いた。

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
