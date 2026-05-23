# COMMERCIALIZATION

PolePole を有償配布するために必要なステップ。製品としての言語化・販売インフラ・運用導線をここで整理する。

ポジションは **「特定の AI ツール / ベンダーに依存せず、CLI で自由に・ストレスなく開発したい人のための macOS ワークスペース」** で確定（編集機能は持たない / Apple Silicon 限定 / 閲覧 + ターミナル + プロジェクト管理に特化）。Claude Code・Codex CLI・gemini CLI など、ターミナルで動く任意の AI コーディング CLI を活かす構成にする。GUI エディタ + AI 統合（Cursor / Zed）や、特定ベンダー専用クライアント（Claude desktop app）と同じ土俵では戦わない。

価格は **買い切り $79 / Lifetime License**（全メジャーバージョン無料アップデート）で確定。サブスク前提のサポート負荷は個人開発では持続しない想定。ターゲットは AI コーディング CLI（Claude Code Pro/Max など、$20〜$200/mo）に課金している層なので、$79 / 一括 は許容範囲内。Lifetime にした以上、収益は新規購入のみなので価格を低めに振らない。

---

## 前提として要らないもの（混同しないようにメモ）

- **TCC 権限のオンボーディング** — エンドユーザー向けには不要。`PolePole.entitlements` は libghostty の hardened runtime 例外だけで、`AXIsProcessTrusted` / `CGRequestScreenCaptureAccess` 等の TCC 保護 API はアプリ本体で呼んでいない。画面収録 / フルディスクアクセス / アクセシビリティが要るのは「PolePole.app の中で PolePole 自身を dogfooding する開発者」のセットアップだけ（→ [CLAUDE.md](../CLAUDE.md) の TCC セクション）
- **編集機能** — 要件 6.4 通り閲覧専用のまま。編集は外部 Cursor / 各自のエディタに逃がす方針を維持
- **クロスプラットフォーム** — Apple Silicon 限定で出す。Intel Mac サポートも当面やらない

---

## MUST（販売開始までに潰す）

### 製品・ブランド

**確定済み:**
- **ブランド名**: PolePole
- **ドメイン**: `polepole.dev` 取得済み（LP / Sparkle 配信フィード / `support@polepole.dev` 等の宛先に使う）

| 項目 | メモ |
|---|---|
| LP（簡易ランディングページ） | `polepole.dev` に最低限の情報だけ載せる: タイトル / 1 文の価値提案 / スクリーンショット 1〜2 枚 / 価格 / 購入ボタン (Stripe Payment Link) / ダウンロード / Zenn 詳細記事へのリンク。**詳細な機能紹介や推奨ワークフローは Zenn の launch 記事側に逃がす**（LP は購入導線に絞る） |
| Zenn の launch 記事 | v1.0 launch の主軸。「エディター作りました」系の自己紹介体で、機能 / 推奨ワークフロー（Claude Code / Codex CLI を使う実例）/ スクリーンショット / 動画 / ショートカット一覧 / FAQ を網羅。記事末尾から `polepole.dev` へ誘導 → 購入へ |
| 環境依存の前提を取り除く | 「自分の Mac だから動く」を排除する。**v1.0 で完璧を求めず、ヤバい依存だけ捕まえるレベルで OK**。具体タスクは下記の段階で進める:<br>**A. grep でコード監査** ✅ **2026-05-23 実施**。配布版アプリ本体に深刻な依存は検出されず（bundled fallback と grace handling が効いている: `~/.config/ghostty/config` 不在時の bundled config 利用、`cursor`/`grep` の Process exec fallback、`POLEPOLE_TEST_*` 環境変数の grace ignore 等）。Explore が「高重大度」と挙げた 5 件は全て開発者向けスクリプト（`.mise.toml` / `scripts/build.sh` / `scripts/polepole-launch.sh` の `/tmp` ハードコード等）でエンドユーザーには無関係<br>**B. HOME 差し替えで起動確認** ⚠️ **2026-05-23 試行 — macOS の API 制約で「clean HOME 検証」としては不成立**。`env -i HOME=/tmp/clean-home PATH=... /Applications/PolePole.app/Contents/MacOS/PolePole` で起動しても、`NSHomeDirectory()` は `getpwuid` の `pw_dir`（= 実 HOME）を見るため、Logger は `/Users/d0ne1s/Library/Logs/polepole/` に書き込み、`~/.config/ghostty/config` 等もそのまま読まれる。clean HOME を本気で再現するには D（新規 macOS ユーザーアカウント）以外に手段なし。**副産物**: env を最低限まで絞っても crash せず起動成功（環境変数の謎依存はないと確認できた）<br>**C. ベータテスター数人（launch 直前）** — 実環境での想定外を最後にすくう。本気で clean 環境を再現したいなら新規 macOS ユーザーアカウント作成検証（D）が必要だが、launch ブロッカー級の不安が残った時だけにする |

### 販売・決済・法務

**確定済み:**
- **価格**: **$79 買い切り / Lifetime License**（全メジャーバージョン無料アップデート、アップグレード料なし）
- **価格モデル**: 買い切り。サブスクは個人開発のサポート負荷で持続しないため不採用
- **無料版**: なし。14 日トライアルのみ
- **トライアル期間**: 14 日
- **期限切れの挙動**: 起動はできるが全機能ロック + 購入案内画面を出す（コアパーツ含めすべて止める。データ取り出し用の脱出口は別途検討）
- **通貨表記**: 市場ステップ（下記）に追従。Stage1 は円建て主軸、Stage3 で $ 主軸

| 項目 | メモ |
|---|---|
| ライセンスキー検証 + アクティベーション | 決済基盤の API でキー検証 → ローカルに署名済みトークン保存。Lifetime License なのでトークンは「有効 / 無効」のフラグだけで OK（purchase version を埋める仕掛けは不要）。トライアル巻き戻し対策として install date は **Keychain** にも書く（Application Support 単体だと再インストールで消える） |
| トライアル実装 | 初回起動時に Keychain + Application Support 両方に install date を書く。両方無い場合のみ「新規」扱い。期限切れ判定は両方の min を取る。期限切れ時は全 view を購入案内画面でラップする（メニュー・ターミナル・プレビュー全て不可） |
| EULA / プライバシーポリシー | LP に必須。最低限「収集する情報」「クラッシュレポートの opt-in」「ライセンス検証通信先」 |
| 特定商取引法表記 | 日本居住で日本居住者にも売るなら法的義務 |
| 利用規約上の制約整理 | 「再配布禁止」「リバースエンジニアリング条項」「無保証」 |

#### 決済基盤（選定済み: Stage1=Stripe → Stage3=Paddle の段階移行）

買い切り + 海外売上想定なら **MoR（Merchant of Record）代行があるかどうか**が一番効く。MoR ありなら VAT / 米国 sales tax / インボイス制度対応を代行業者が肩代わりするので、個人事業の税務負荷が大幅に軽くなる。Stripe は MoR ではないので、海外売上が一定以上になると自前で各国税対応が必要になり、個人だと持続しない。

| 候補 | MoR | 手数料の目安 | 強み | 弱み | 採用ステータス |
|---|---|---|---|---|---|
| **Stripe** | ✗ | 3.6% + ¥40/tx | 国内最安・API が一番良い・実装情報も豊富 | MoR でないので海外売上時の VAT/sales tax は全部自前。個人事業だと持続しづらい。ライセンスキー発行は自作 | **Stage1 採用** |
| **Paddle** | ✓ | 5% + $0.50/tx | MoR で税務代行込み。SaaS / desktop アプリ実績多数。ライセンスキー発行 API あり | 手数料がやや高い。審査がある。JCB が弱く国内決済の取りこぼしあり | **Stage3 で採用予定** |
| **Lemon Squeezy** | ✓ | 5% + $0.50/tx | MoR 代行込み。個人開発者人気で UI/DX が良い。ライセンスキー発行 API あり | 2024 に Stripe 買収。今後の統合方針が不透明（Stripe 側に吸収されるとブランド消滅リスク） | 選定外 |

**Stage 別の運用方針**:
- **Stage1 (国内・円建て)**: **Stripe**。¥11,800 等の円表記で JCB 含めて受ける。MoR が要らないので税務はインボイス制度のみ自前
- **Stage2 (ドル併記、海外売上が出始める)**: Stripe 継続 + 海外売上が一定額を超えたら Paddle へ並走を検討。EU 売上が VAT の閾値（年 €10,000）を超えるとそこから自前 VAT 登録が要るので、その手前で Paddle 移行
- **Stage3 (ドル主軸・海外メイン)**: **Paddle** に統一。MoR で各国税対応をオフロード。Stripe は国内専用の予備に残してもいい

##### なぜ Stage1 から Paddle に寄せないのか

「将来 Paddle に移行するなら最初から Paddle にしておけば移行コストゼロ」という選択肢は **却下した**。理由:

- **JCB 弱い**: Paddle は JCB の受けが弱く、国内 launch (Stage1=Zenn 記事 + 日本語 LP) で取りこぼしが launch 直後から確定で乗る
- **手数料 +1.4%**: ¥11,800 取引で Stripe `3.6%+¥40` ≈ ¥465、Paddle `5%+$0.50` ≈ ¥665。差 +¥200/件が全件に乗る
- **Paddle 審査**: 個人開発の desktop アプリでも数日〜数週間。launch のクリティカルパスに乗せたくない
- **そもそも Stage3 まで行かないシナリオがある**: 海外売上が出ずに Stage1 で終わるなら MoR の旨味はゼロ、手数料差だけが残って損

つまり **Stripe で始めるのはオプション保有戦略**。Stage3 まで行ければ Paddle に移行、行かなければそのまま Stripe で完結、どちらに転んでも軽症。

##### Stripe → Paddle 移行のコスト見積もり

移行を決断したときに「思ったより重かった」とならないよう、現行設計での見積もりを残しておく (設計詳細は [docs/plans/2026-05-23-payment-and-licensing.md](./plans/2026-05-23-payment-and-licensing.md))。

**動かすもの**:
- Workers に `/paddle-webhook` ハンドラ 1 個追加 (`/stripe-webhook` と併存 OK)
- LP の購入ボタン URL を Stripe Payment Link → Paddle Checkout に置換 (HTML 1 行)
- D1 の `license` テーブルに `paddle_transaction_id` カラム追加 (`stripe_session_id` は既存購入の履歴として残す)

**動かないもの (ゼロ修正で済む)**:
- アプリ側のライセンス検証ロジック (キー形式 `polepole-XXXX-...`・署名トークン構造・公開鍵検証・全部決済プロバイダ中立)
- 既存ユーザーのライセンスキー (Stripe で買った人もそのまま使い続けられる)
- 利用規約・プライバシーポリシー (販売事業者は同じ、決済代行が変わるだけ)
- アクティベーション / デバイス管理 API

見積もり工数: **2-3 日**程度。これは「アプリ側のライセンス検証が決済プロバイダ非依存」に設計してある前提なので、本 plan ではこの不変条件を死守する。Lemon Squeezy は Stripe 買収で今後が不透明なため現時点では選定外（ただし Stripe 統合が進んで MoR ベースの選択肢が公式に出てきたら再評価）。

### 運用・サポート

| 項目 | メモ |
|---|---|
| サポート窓口 | `support@polepole.dev` 1 本でいい。Discord / Slack はサポート負荷が想像以上に高いので最初は持たない |
| アプリ内フィードバック導線 | メーラー起動でも可。本文に **バージョン / OS / 直近ログ末尾 / 環境変数の一部** を prefill しておく（これだけでサポートコストが激減する） |
| クラッシュレポート | Sentry（個人開発者プランは無料枠あり）。**opt-in** で送信。落ちた理由が分からないとリピート購入が止まる |
| 配信フィードの独自ドメイン化 | `updates.polepole.dev/appcast.xml` に移行（R2 + 独自ドメイン）。旧 SUFeedURL（`nyshk97/polepole-releases`）を踏むユーザーのために GitHub 側にも appcast を残す（リダイレクトが効かないので両方更新する運用） |

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

## 市場展開ステップ

「いつ何をやるか」のロードマップ。MUST/SHOULD/NICE で what を決め、Stage で when を決める。

### Stage1: 国内・円建て（v1.0 launch）

**launch ファネル**: Zenn 記事を主軸に集客 → 簡易 LP で購入導線に絞る、というシンプルな 2 段構成。

1. **Zenn に「エディター作りました」記事を投稿** — 機能 / 推奨ワークフロー / スクリーンショット / 動画 / ショートカット一覧 / FAQ を全部入れる。X (@nyshk97) でも告知して Claude Code / Codex CLI 文脈の技術コミュニティに拡散
2. **記事末尾から `polepole.dev`（簡易 LP）へ誘導** — LP には最低限の情報だけ。タイトル / SS / 価格 / 購入ボタン / ダウンロード
3. **LP の購入ボタン → Stripe Payment Link** — 決済完了でライセンスキーをメール送信
4. **アプリ起動でアクティベート** — トライアル期間中の人もキー入力で即 unlock

| 項目 | 内容 |
|---|---|
| 表示価格 | **¥11,800**（≒ $79、為替バッファ込み） |
| 決済 | Stripe Payment Link（JCB 含む国内 4 ブランド + 海外発行カードも一応通す）。Stripe Dashboard でライセンスキー発行を webhook 連動 |
| LP | `polepole.dev`（日本語のみ・購入導線特化） |
| 詳細紹介 | Zenn 記事に集約。LP からは記事へのリンクを置く |
| 告知 | X（@nyshk97）/ Zenn / Qiita / はてブ。AI コーディング CLI（Claude Code / Codex CLI 等）文脈でつながっている技術コミュニティへリーチ |
| 法務 | 特定商取引法表記・利用規約・プライバシーポリシー（日本語）。LP にリンクを置く |
| MoR | 不要（売上の大半が国内なので個人事業の確定申告 + インボイス制度対応で済む） |
| KPI | 月の本数、Zenn 記事の reach（いいね / ブクマ / 流入元）、LP の CVR、サポート問い合わせ件数 |

**Stage2 への卒業条件**: 海外問い合わせ / 海外売上が継続的に発生し始める、Product Hunt 等での流入が見えてきたら次へ。

### Stage2: ドル併記（v1.x）

| 項目 | 内容 |
|---|---|
| 表示価格 | **¥11,800 / $79** 両表記 |
| 決済 | Stripe 継続。海外売上が増えたら Paddle と並走（移行は次 Stage） |
| LP | 日本語 + 英語並記。スクリーンショット / 動画は文字少なめで両対応 |
| エンドユーザー向け help サイト | LP / Zenn 記事だけでは答えられない FAQ・トラブルシュート・ライセンス管理手順を切り出した help サイトを `docs.polepole.dev` 等に立てる（Stage1 ではここに到達するほどの問い合わせ量が出ない想定なので不要） |
| 告知 | 英語 X アカウント（必要なら）、IndieHackers、Hacker News |
| 法務 | 英語版利用規約・プライバシーポリシーを追加 |
| MoR | EU/UK の VAT 閾値（年 €10,000 / £8,818）接近で Paddle 移行を仕掛ける |
| KPI | 海外売上比率、各国 VAT 閾値の接近度合い |

**Stage3 への卒業条件**: EU/UK の VAT 閾値に到達 or 海外売上が国内売上を超える。

### Stage3: ドル主軸・海外メイン（v2.x 以降）

| 項目 | 内容 |
|---|---|
| 表示価格 | **$79**（¥表記はサブ） |
| 決済 | **Paddle 統一**（MoR で各国税対応オフロード）。Stripe は国内決済の予備として残しても OK |
| LP | 英語主、日本語はサブ |
| 告知 | Product Hunt launch、英語メディア（TechCrunch / The Verge 系より個人開発系メディアが現実的） |
| 法務 | Paddle の MoR で大半カバー。日本国内向け特商法表記は引き続き必要 |
| MoR | Paddle に全寄せ |
| 検討事項 | 法人化（個人事業のままだと売上規模が大きくなった時に税負担が重くなる） |

---

## SHOULD（最初のリリース後すぐ）

| 項目 | メモ |
|---|---|
| 起動時の環境チェック常駐表示 | `~/.config/ghostty/config` 不在 等を要件 8.3 の常駐表示に出す（BACKLOG の「dotfiles / CloudStorage が読めない案内」を一般化）。**特定の AI CLI（`claude` 等）の有無はチェック対象にしない**（ベンダー非依存方針） |
| 診断情報のワンクリックコピー | バージョン / OS / 環境変数 / 直近ログ末尾をクリップボードへ。サポート対応コストが激減 |
| 更新チャネル分離（stable / beta） | Sparkle delegate でユーザーが選択可能に。pro ユーザーに beta 先行配布したい場合の布石にも |
| EdDSA 秘密鍵紛失時のリカバリ運用 | Dropbox バックアップを消さない運用ルールは [docs/DEV.md](./DEV.md#eddsa-鍵) 通り。鍵紛失時の旧版ユーザー救済フローも文書化しておく |

---

## NICE（売れ始めてから検討）

| 項目 | メモ |
|---|---|
| リフェラル | 既存ユーザーが友人を紹介して割引が出る仕組み。Lifetime なので「次回購入の割引」は使えない → 紹介報酬は Amazon ギフトカード等の現金等価で出す前提 |
| 比較記事 / 紹介記事 | vs Cursor / vs cmux / vs Warp |
| プラン分け（個人 / チーム） | 売れ行きを見てから |

---

## オープン論点（先に決めておくべき）

確定したもの:
- ~~ブランド名~~: **PolePole**で確定（ドメイン `polepole.dev` 取得済み）
- ~~価格モデル~~: **買い切り**で確定
- ~~無料版を残すか~~: **無料版なし、14 日トライアルのみ**で確定
- ~~買い切り金額~~: **$79 / ¥11,800（Lifetime License）**で確定
- ~~アップグレード料運用~~: **なし**（全バージョン無料アップデート）で確定
- ~~決済基盤の最終選定~~: Stage1=Stripe → Stage3=Paddle の段階移行で確定
- ~~海外売上の比率想定~~: Stage1=国内主、Stage3=海外主、段階的に移行で確定

引き続き保留:
- **法人格** — Stage1〜2 は個人事業で OK。Stage3 で売上規模を見て法人化判断
- **Stage 卒業の具体的な閾値** — 国内売上 N 円 / 月や、海外売上 M ドル / 月など、Stage2→3 へ移る目安金額

---

## 関連ドキュメント

- 残タスク全般: [docs/BACKLOG.md](./BACKLOG.md)
- Sparkle 自動更新: [docs/DEV.md の Sparkle 節](./DEV.md#sparkle-自前アップデート)
- Sparkle セットアップの実装計画: [docs/plans/2026-05-14-sparkle-auto-update.md](./plans/2026-05-14-sparkle-auto-update.md)
