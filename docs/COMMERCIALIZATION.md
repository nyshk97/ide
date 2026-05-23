# COMMERCIALIZATION

ide を有償配布するために必要なステップ。今は「自分用ツール」前提の README / REQUIREMENTS のままなので、製品としての言語化・販売インフラ・運用導線を整える必要がある。

ポジションは **「Claude Code を最高に回せる macOS ワークスペース」**（編集機能は持たない / Apple Silicon 限定 / 閲覧 + ターミナル + プロジェクト管理に特化）で確定。Cursor / Zed と同じ土俵では戦わない。

価格帯の現実解は **買い切り $15〜$25（メジャーバージョン毎にアップグレード料）** あたり。サブスク前提のサポート負荷は個人開発では持続しない想定。

---

## 前提として要らないもの（混同しないようにメモ）

- **TCC 権限のオンボーディング** — エンドユーザー向けには不要。`PolePole.entitlements` は libghostty の hardened runtime 例外だけで、`AXIsProcessTrusted` / `CGRequestScreenCaptureAccess` 等の TCC 保護 API はアプリ本体で呼んでいない。画面収録 / フルディスクアクセス / アクセシビリティが要るのは「PolePole.app の中で PolePole 自身を dogfooding する開発者」のセットアップだけ（→ [CLAUDE.md](../CLAUDE.md) の TCC セクション）
- **編集機能** — 要件 6.4 通り閲覧専用のまま。編集は外部 Cursor / 各自のエディタに逃がす方針を維持
- **クロスプラットフォーム** — Apple Silicon 限定で出す。Intel Mac サポートも当面やらない

---

## MUST（販売開始までに潰す）

### 製品・ブランド

| 項目 | メモ |
|---|---|
| 固有のブランド名 + ドメイン取得 | "PolePole" は検索性ゼロ・商標リスクあり。1 単語 + `.app` か `getxxx.com` あたり |
| LP（ランディングページ） | 「何ができるか」「Claude Code を使った推奨ワークフロー」「スクリーンショット / 動画」「ショートカット一覧」「FAQ」「価格」「ダウンロード」 |
| エンドユーザー向けドキュメント | 現在の docs は開発者向け。LP からリンクできる help サイト or 単一 README |
| 環境依存の前提を取り除く | `mise` / `brew` / dotfiles を持たないユーザーで動くこと。JetBrains Mono と ghostty bundled config は同梱済みなので、`claude` の有無 / `~/.config/ghostty/config` 不在時のデフォルト挙動を確認 |
| `claude` CLI 未インストール時の案内 | 起動後・ターミナル初回利用時に「Claude Code がインストールされていません → install ガイドへ」を出す。要件 8.3 の常駐表示 or 初回モーダル |
| README / REQUIREMENTS の語り直し | 現在「自分用」と書いてあるので、製品としての positioning に置き換え。または ide 本体 repo を private 化するなら公開 README は LP に統合 |

### 販売・決済・法務

| 項目 | メモ |
|---|---|
| 決済基盤の選定 | **Paddle** か **Lemon Squeezy**（VAT / MoR 代行込み）。Stripe 直は日本居住個人だと税務が重い。両社ともライセンスキー発行 API あり |
| ライセンスキー検証 + アクティベーション | Paddle / LS の API でキー検証 → ローカルに署名済みトークン保存。Sparkle の `feedURLString(for:)` でユーザー別 appcast を返せるので、契約切れ時に旧版固定にできる |
| トライアル期間 | 起動時に install date を Application Support に書いて、N 日経過後にメニューと一部機能を制限。N は 14 日 or 30 日が一般的 |
| EULA / プライバシーポリシー | LP に必須。最低限「収集する情報」「クラッシュレポートの opt-in」「ライセンス検証通信先」 |
| 特定商取引法表記 | 日本居住で日本居住者にも売るなら法的義務 |
| 利用規約上の制約整理 | 「再配布禁止」「リバースエンジニアリング条項」「無保証」 |

### 運用・サポート

| 項目 | メモ |
|---|---|
| サポート窓口 | `support@<domain>` 1 本でいい。Discord / Slack はサポート負荷が想像以上に高いので最初は持たない |
| アプリ内フィードバック導線 | メーラー起動でも可。本文に **バージョン / OS / 直近ログ末尾 / 環境変数の一部** を prefill しておく（これだけでサポートコストが激減する） |
| クラッシュレポート | Sentry（個人開発者プランは無料枠あり）。**opt-in** で送信。落ちた理由が分からないとリピート購入が止まる |
| 本体 repo の private 化 | 配信は `nyshk97/polepole-releases` に集約済み。`homebrew-tap` の cask URL を `ide-releases` に向け直してから private 化 |
| 配信フィードの独自ドメイン化 | `updates.<domain>/appcast.xml`。R2 + 独自ドメインへ移行。旧 SUFeedURL を踏むユーザーのために GitHub 側にも appcast を残す（リダイレクトが効かないので両方更新する運用） |

### 依存物のライセンス整理

| 項目 | メモ |
|---|---|
| libghostty / ghostty | MIT。クレジット表記必須 |
| highlight.js | BSD-3-Clause。クレジット表記必須 |
| JetBrains Mono | OFL。同梱済み（[bundled commit](../../../commits/8f280e7)）。配布アプリにも OFL 表記とフォントを同梱 |
| cmux 由来コード | 参考実装として参照。直接コピーした箇所があるなら来歴を明示 |
| Sparkle | MIT |

アプリ内「ライセンス / クレジット」画面にまとめる（標準的な OSS バンドル表示）。

---

## SHOULD（最初のリリース後すぐ）

| 項目 | メモ |
|---|---|
| 起動時の環境チェック常駐表示 | `claude` not found / `~/.config/ghostty/config` 不在 等を要件 8.3 の常駐表示に出す（BACKLOG の「dotfiles / CloudStorage が読めない案内」を一般化） |
| 診断情報のワンクリックコピー | バージョン / OS / 環境変数 / 直近ログ末尾をクリップボードへ。サポート対応コストが激減 |
| 更新チャネル分離（stable / beta） | Sparkle delegate でユーザーが選択可能に。pro ユーザーに beta 先行配布したい場合の布石にも |
| EdDSA 秘密鍵紛失時のリカバリ運用 | Dropbox バックアップを消さない運用ルールは [docs/DEV.md](./DEV.md#eddsa-鍵) 通り。鍵紛失時の旧版ユーザー救済フローも文書化しておく |

---

## NICE（売れ始めてから検討）

| 項目 | メモ |
|---|---|
| 英語ローカライズ | 海外市場を取りに行くなら UI / LP / help を英語化 |
| アップグレード割引・リフェラル | メジャーバージョンアップ時の既存ユーザー優遇 |
| Product Hunt / X での告知 | リリース launch の段取り |
| 比較記事 / 紹介記事 | vs Cursor / vs cmux / vs Warp |
| プラン分け（個人 / チーム） | 売れ行きを見てから |

---

## オープン論点（先に決めておくべき）

- **ブランド名** — 一語、覚えやすく、商標調査済みであること
- **価格モデル** — 買い切り vs サブスク。買い切りなら「メジャーバージョン毎にアップグレード料」運用を最初から仕込んでおく（後から変えにくい）
- **無料版を残すか** — OSS 版 + 有料版にするのか、完全クローズドにするのか。OSS 版を残すなら何を有料機能にするか
- **法人格** — 個人事業 vs 法人。Paddle / LS は個人事業でも契約可
- **海外売上の比率想定** — 日本国内だけで価格を考えるか、ドル建てで考えるか

---

## 関連ドキュメント

- 残タスク全般: [docs/BACKLOG.md](./BACKLOG.md)
- Sparkle 自動更新: [docs/DEV.md の Sparkle 節](./DEV.md#sparkle-自前アップデート)
- Sparkle セットアップの実装計画: [docs/plans/2026-05-14-sparkle-auto-update.md](./plans/2026-05-14-sparkle-auto-update.md)
