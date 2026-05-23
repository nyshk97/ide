# 決済・ライセンス基盤

## 概要・やりたいこと

PolePole v1.0 を有償配布 ($79 / ¥11,800 / Lifetime License) するための決済・ライセンス基盤を構築する。Stage1 (国内・円建て) 向けに、Stripe Payment Link + Cloudflare 基盤 + macOS アプリ側のトライアル / アクティベーション機構を一通り設計する。

範囲:
- 購入導線 (LP / Stripe Payment Link / success_url)
- ライセンスキーの発行・配布 (Stripe webhook → D1 → Resend)
- アプリ側のトライアル管理 (Keychain + Application Support / 14日 / 期限切れロック)
- アプリ側のアクティベーション / ローカル検証 (EdDSA 署名トークン / オフライン動作 / 週1再検証)
- 3 台までのデバイス管理とスワップ UI
- ユーザー救済 (キー再発行 / サ終時 universal token)

範囲外 (将来):
- Stage2/3 のドル併記・Paddle 移行
- アップデートチャネル分離 (stable/beta)
- リフェラル / 学割 / プラン分け
- アプリ内クラッシュレポート (Sentry)
- **appcast の R2 / 独自ドメイン (`updates.polepole.dev`) への移行** — 既存の Sparkle feed は GitHub Releases 固定 (`Resources/Info.plist` の `SUFeedURL` + `scripts/release.sh`)。R2 移行は本 plan のスコープから外し、別 plan (`docs/plans/<date>-appcast-to-r2.md`) に切り出す。本 plan の Cloudflare 基盤は appcast とは独立に動く前提

詳細な戦略・ポジショニングは [docs/COMMERCIALIZATION.md](../COMMERCIALIZATION.md) を参照。

## 前提・わかっていること

### 確定済み (dig 2026-05-23 で決定)

**ライセンス検証**
- ハイブリッド方式: 初回オンライン認証 → ローカル署名トークン保存 → 起動毎はローカル検証
- 認証単位: **メアド + ライセンスキー両方**を要求 (盗難耐性)
- 暗号: **EdDSA (Ed25519)**。Sparkle 鍵とは別鍵 (漏洩時の被害切り分け)
  - **秘密鍵 = Cloudflare Workers env のみ** (署名はサーバーだけ。ローカルでは絶対に持たない。サ終時の universal token 署名用のオフライン秘密鍵は別管理で Dropbox dotfiles に保管)
  - **公開鍵 = アプリにバンドル** (`Resources/license-pubkey.pem`)。アプリは検証のみ
- 再検証: バックグラウンドで週1。**verify 成功するたびに新しい署名トークン (issued_at 更新済み) を返し、アプリ側で Keychain に上書き保存する**。トークン自体は `issued_at + 30 日` で有効期限が切れる短寿命設計だが、毎週 verify が成功する限り自動延長されるので体感は無期限
- ロック条件: ローカルトークンの `issued_at + 30 日` を超えた時点で `LicenseState.deactivated`。すなわち **「最後に verify 成功してから 30 日経過」** で grace 切れ。verify 自体は週1 試行、失敗してもトークンは残るので、30 日以内に 1 回でも成功すれば延命される

**トライアル**
- 14 日。完全ローカル (サーバー通知ゼロ、anonymous)
- install date を **Keychain + Application Support** 両方に書き、min を採用
- 期限切れで全 view を購入案内画面でラップ

**複数台インストール**
- 1 ライセンス = **3 台** まで同時アクティベート
- デバイス識別: `IOPlatformExpertDevice` UUID の SHA256
- 上限超過時: アプリ内「最古デバイスを deactivate してスワップ」ダイアログ

**インフラ (全部 Cloudflare に寄せる)**
- LP: vanilla HTML + CSS → Cloudflare Pages (`polepole.dev`)
- API + webhook: Cloudflare Workers
- DB: Cloudflare D1
- ストレージ: Cloudflare R2 (appcast と統合)
- メール送信: Resend (無料枠 月 3000 通)
- 決済: Stripe Payment Link (¥11,800 円建て)

**キー受け渡し**
- Stripe webhook → D1 書き込み → Resend でメール送信
- success_url ページ (`polepole.dev/thanks?session_id=...`) でも表示 (webhook 失敗時の保険)

**Lifetime の範囲**
- 全 major version 無料アップデート (v1 / v2 / v3 すべて)

**サ終救済**
- 利用規約に「90 日前 universal token メール配布」を明記
- 実装はサ終時 (EdDSA 秘密鍵で署名するスクリプトをローカルに用意するのみ)

**UI 配置**
- キー入力 UI: 購入案内画面 + Settings 両方に配置
- 期限切れ前は Settings、期限切れ後は購入画面から入力可能

### Swift / アプリ側の前提
- macOS 専用 / Apple Silicon 限定 / SwiftUI / Sparkle 自動更新
- `AppPaths.subdirName` で Debug=`polepole-dev` / Release=`polepole` に振り分け済み (新規パスもこれに従う)
- `Logger.shared` が唯一のログ経路。`ErrorBus.shared.notify` が toast 経路
- Keychain 書き込みの既存実装はなし (新規追加)
- 期限切れロックは要件 6 / 8.3 に整合 (機能の全停止 + 案内表示)

### キーフォーマット (案、実装時に再確認)
- `polepole-XXXX-XXXX-XXXX-XXXX` (大文字英数字 16 文字を 4-4-4-4 で区切る)
- prefix `polepole-` で他サービスのキーと識別しやすい
- ハイフン区切りでコピペしやすく、目視確認も楽
- DB 上は prefix 含めて UNIQUE

### DB スキーマ (案、Phase 2 で詳細詰め)
```sql
-- license: 購入単位
license (
  id            TEXT PRIMARY KEY,          -- polepole-XXXX-...
  email         TEXT NOT NULL,             -- 購入時メアド (認証単位)
  stripe_session_id TEXT NOT NULL UNIQUE,
  stripe_payment_intent_id TEXT,
  amount        INTEGER NOT NULL,
  currency      TEXT NOT NULL,             -- 'jpy' (Stage1) / 'usd' (Stage2+)
  status        TEXT NOT NULL,             -- active / revoked / refunded
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
);

-- device: ライセンスに紐付くデバイス (上限 3)
device (
  id            TEXT PRIMARY KEY,          -- UUID v4 (server-side)
  license_id    TEXT NOT NULL REFERENCES license(id),
  device_hash   TEXT NOT NULL,             -- SHA256(IOPlatformExpertDevice UUID)
  device_name   TEXT,                      -- ComputerName (表示用)
  os_version    TEXT,
  app_version   TEXT,
  activated_at  INTEGER NOT NULL,
  last_seen_at  INTEGER NOT NULL,
  UNIQUE(license_id, device_hash)
);

-- purchase_log: 監査用 (webhook 受信履歴等)
purchase_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type    TEXT NOT NULL,             -- checkout.session.completed / refund.created etc
  stripe_event_id TEXT NOT NULL UNIQUE,    -- idempotent fulfillment 用に UNIQUE
  source        TEXT NOT NULL,             -- 'webhook' / 'thanks_page' (どちらが先に処理したか追跡)
  payload       TEXT NOT NULL,             -- JSON
  received_at   INTEGER NOT NULL
);

-- rate_limit_log: メール再送等のスロットリング用 (Cloudflare Rate Limiting で取れない粒度の補強。第一選択は Workers の rateLimit binding)
rate_limit_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  key           TEXT NOT NULL,             -- 'resend:<email>' / 'activate:<ip>' etc
  occurred_at   INTEGER NOT NULL,
  INDEX(key, occurred_at)
);
```

**Idempotent fulfillment**: webhook と /thanks の両方から license 発行を呼ぶため、`stripe_session_id` を UNIQUE にして `INSERT ... ON CONFLICT DO NOTHING` で重複を吸収する。`purchase_log.stripe_event_id` も UNIQUE。

**デバイス上限の原子性**: `count → insert` を別クエリでやると並列 activate で 4 台目が入る競合が起きる。D1 の batch (statement の transaction) で

```sql
-- 単一 batch で実行
SELECT COUNT(*) AS n FROM device WHERE license_id = ?;
INSERT INTO device (...) SELECT ?, ?, ?, ?, ?, ?, ? WHERE (SELECT COUNT(*) FROM device WHERE license_id = ?) < 3;
```

または `INSERT ... WHERE NOT EXISTS (SELECT ... HAVING COUNT(*) >= 3)` で原子化する。Phase 3 で具体実装。

### API エンドポイント (案、Phase 3 で詳細詰め)
- `POST /stripe-webhook` — Stripe 署名検証 → 共通の `fulfillCheckout(sessionId)` を呼ぶ
- `GET /thanks?session_id=...` — Stripe success_url 用。**Stripe API で Checkout Session を取得し検証** (`payment_status == "paid"`、想定 Price ID 一致、`amount_total` / `currency` 一致) → 共通の `fulfillCheckout(sessionId)` を呼ぶ → 完了後 license を D1 から引いて表示
- 共通関数 `fulfillCheckout(sessionId)`: Stripe API で session 再取得 → 上記の検証条件をすべてチェック → `INSERT ... ON CONFLICT DO NOTHING` で license を作成 (重複時は no-op) → Resend で送信 (これも idempotent: `purchase_log` を見て送信済みなら skip)
- `POST /v1/license/activate` — `{ key, email, device_hash, device_name, os, app_version }` → 署名トークン or `{ error: "device_limit", existing_devices: [...] }`
- `POST /v1/license/deactivate` — `{ key, email, device_id }` → 古いデバイスを抹消
- `POST /v1/license/verify` — 週1再検証用。`{ key, email, device_hash }` → **成功時は新しい署名トークン (issued_at 更新済み) を返す**。`license.status` が active 以外なら `{ error: "revoked" }` / device 不在なら `{ error: "unknown_device" }`
- `POST /v1/license/resend` — 紛失時の再送 (rate limit 必須、後述)

### webhook 受信時の検証条件 (Stage1 想定)
`fulfillCheckout(sessionId)` 内で以下をすべてチェック。失敗時は purchase_log に記録だけして fulfillment は行わない (Stripe Dashboard で要確認の旨アラート)。

- `event.type == "checkout.session.completed"`
- `session.payment_status == "paid"` (`unpaid` / `no_payment_required` は弾く)
- `session.amount_total == 11800` (Stage1 円建て)
- `session.currency == "jpy"`
- `session.line_items[0].price.id == <想定 Price ID>` (環境変数で持つ)
- `session.payment_link == <想定 Payment Link ID>` (テスト/本番のクロス混入防止)

**遅延決済の扱い**: Stage1 ではコンビニ払い・銀振等の遅延決済は **扱わない**。Stripe Payment Link 側で `payment_method_types: ["card"]` のみに限定する。これにより `checkout.session.async_payment_succeeded` を listen する必要がなくなる。Stage2 以降で需要が出たら別途検討。

### Rate limit の実装方式
- **第一選択**: Cloudflare の Rate Limiting Rules / Workers の `rateLimit` binding (`@cloudflare/workers-types` の `RateLimit` interface)。IP ベース / ヘッダーベースで秒/分単位の制限を設定でき、スキーマ不要
- **補強**: `resend` のような「同じ email から N 回」を制限したいケースは IP ベースでは取れないので `rate_limit_log` テーブルで補強
- 想定: `resend` = 同じ email から 1 分 1 回 / 1 日 5 回。`activate` = 同じ IP から 10 秒 1 回

### 署名トークンの構造 (案、Phase 4 で詳細詰め)
- ペイロード (JSON): `{ key, email, device_hash, license_status, issued_at, max_offline_days: 30 }`
- 署名: EdDSA (Ed25519) でペイロードを署名 → base64url で連結 (`<payload>.<signature>`)
- アプリ側は埋め込まれた公開鍵で検証。`issued_at + max_offline_days < now()` ならローカル grace 切れ判定
- **トークンは短寿命 + verify で自動延長する設計**: activate 成功時と verify 成功時に毎回新しい token (issued_at 更新済み) を返す。アプリは Keychain の token を上書き保存する。週1 verify が成功する限り、`issued_at + 30 日` は連続的に未来へ伸びるので体感は無期限。連続 30 日 verify 失敗 (= ネット断絶 / サーバー停止 / アプリ未起動の連鎖) で初めて grace 切れ
- **時計巻き戻し対策**: `issued_at > now() + 大きな skew` を異常として扱う。短期的な時計ズレ吸収のため Keychain に「これまで観測した最大 now」を残しておき、`max(now, last_observed_now)` で判定 (なんちゃって monotonic clock)

## 実装計画

### 事前準備 [人間👨‍💻]
- [ ] Stripe アカウント作成 + 個人事業の本人確認完了 (国内で売る場合は特商法住所の確認)
- [ ] Stripe Test mode の API key を控える (Workers の env で使う)
- [ ] Cloudflare アカウント作成 (既存があれば流用)
- [ ] `polepole.dev` の DNS を Cloudflare に向ける (取得済み前提)
- [ ] Resend アカウント作成 + `polepole.dev` のドメイン認証 (SPF/DKIM レコードを Cloudflare DNS に追加)
- [ ] 特定商取引法表記の文面準備 (個人事業者氏名 / 住所 / 連絡先)
- [ ] 利用規約 / プライバシーポリシーのドラフト作成 (サ終時の universal token 配布条項を含む)
- [ ] EdDSA 鍵ペアの生成 (Sparkle のアプリ署名用とは別鍵)
  - **秘密鍵**: Cloudflare Workers の env (`LICENSE_SIGNING_PRIVATE_KEY`) に登録。サ終時の universal token 署名用のバックアップとして Dropbox dotfiles にも 1 部保管 (Sparkle 鍵と同運用)
  - **公開鍵**: アプリにバンドル (`Resources/license-pubkey.pem`)。git にコミット (公開してよい)

### Phase 1: Cloudflare 基盤の構築 [AI🤖]
- [x] ~~`polepole-backend/` リポジトリを新規作成 (PolePole 本体とは別 repo にする。OSS にしない前提)~~ → **monorepo に変更**。`backend/` ディレクトリとして本 repo に含める。理由はログ参照
- [x] Wrangler セットアップ (`backend/wrangler.toml`、Workers + D1 + Rate Limiter bindings)。R2 は本 plan では使わない (appcast 移行は別 plan)
- [x] D1 スキーマ作成 (license / device / purchase_log / rate_limit_log)。`backend/migrations/0001_initial.sql`、`wrangler d1 migrations apply --local` でローカル適用済み
- [x] EdDSA 鍵生成スクリプト (`backend/scripts/gen-license-keys.sh`) を用意。秘密鍵は dotfiles 配下、公開鍵は `Resources/License/` にバンドル。秘密鍵の Workers env 投入 (`wrangler secret put LICENSE_SIGNING_PRIVATE_KEY`) は事前準備の人間タスク
- [x] Rate Limiting binding を `wrangler.toml` に追加 (`unsafe.bindings` 経由、experimental)
- [x] CORS 設定 (緩い `*` 許可、認証は API 側で行う方針)
- [x] アプリ側 `project.yml` に `Resources/License` を `buildPhase: resources` で追加 (公開鍵バンドル経路)
- [x] 動作確認: `pnpm install` / `pnpm typecheck` / `pnpm test` / `pnpm db:migrate:local` / `wrangler dev --local` 起動 + 各エンドポイントへの curl で 200/501/404 を確認

### Phase 2: ライセンス発行フロー [AI🤖]
- [x] 共通 fulfillment 関数 `fulfillCheckout(sessionId, source, eventId?)` を実装 (`src/lib/fulfillment.ts`)
  - [x] Stripe API で session を取得 (webhook payload は信用せず必ず取得し直す)
  - [x] **検証条件をすべてチェック** (`validateSession` を pure 関数に切り出し): `payment_status == "paid"` / `amount_total == 11800` / `currency == "jpy"` / Price ID 一致 / Payment Link ID 一致 + email 必須
  - [x] D1 から `stripe_session_id` を引き、既にあれば早期 return (idempotent)
  - [x] キー生成: `polepole-XXXX-XXXX-XXXX-XXXX` (Phase 1 で実装済み)
  - [x] `INSERT INTO license ... ON CONFLICT (stripe_session_id) DO NOTHING` で license 作成
  - [x] `purchase_log` に `source` 付きで記録 (webhook 経由で eventId がある場合のみ)
  - [x] Resend で送信 (`purchase_log.email_sent` フラグで二重送信防止)、`RESEND_ENABLED=false` or placeholder key で noop モードあり
- [x] Stripe webhook エンドポイント (`POST /stripe-webhook` / `src/routes/webhook.ts`)
  - [x] Stripe 署名検証 (`src/lib/stripe.ts` の `verifyStripeSignature`、HMAC-SHA256、5 分 tolerance、複数 v1 対応)
  - [x] `event.type == "checkout.session.completed"` を `fulfillCheckout("webhook")` に流す
  - [x] `refund.created` / `charge.refunded` → `markRefunded` で `license.status = "refunded"`
  - [x] 未対応イベントは 200 で受け流す
- [x] success_url ページ (`GET /thanks?session_id=...` / `src/routes/thanks.ts`)
  - [x] `fulfillCheckout("thanks_page")` で webhook 未着の保険を兼ねる
  - [x] HTML 描画 (キー + メアド + アクティベート手順 + サポートリンク)
  - [x] エラー時の friendly 案内
- [x] Stripe Payment Link 側の設定方針: `backend/README.md` と `backend/scripts/setup-stripe-products.sh` に反映 (card-only、success_url=`/thanks?session_id={CHECKOUT_SESSION_ID}`、顧客 email 必須)
- [x] テスト: stripe-signature 6 ケース + fulfillment-validation 12 ケース (合計で全 23 テスト pass)
- [x] 動作確認: `wrangler dev --local` で全ルート疎通、`/thanks?session_id=...` で実 Stripe Sandbox API に到達して 404 取得まで確認

### Phase 3: アクティベーション API [AI🤖]
- [x] `POST /v1/license/activate` (`src/routes/license.ts` + `src/lib/license-ops.ts`)
  - [x] `key + email` で license を引く (`lookupLicense`、email は case-insensitive)。両方一致しないと 401、revoked/refunded なら 403
  - [x] **原子的に device 上限チェック + insert/update**: D1 batch で 3 statement (UPDATE / INSERT WHERE NOT EXISTS AND COUNT<3 / SELECT) を実行
  - [x] 既に 3 台ある場合は `{ error: "device_limit", existing_devices: [...] }` を 409 で返す
  - [x] 新規登録 or 既存更新成功時に EdDSA で署名済みトークンを発行
- [x] `POST /v1/license/deactivate`
  - [x] `key + email + device_id` で device を削除 (`license_id` 一致を WHERE に必須化で他人の device 削除を防止)
- [x] `POST /v1/license/verify` (`verifyAndRefresh`)
  - [x] `last_seen_at` / `os_version` / `app_version` を更新
  - [x] **成功時に新しい署名トークン (issued_at = now()) を返す** → アプリ側で Keychain 上書き = 30 日 grace 自動延長
  - [x] device 不在は `{ error: "unknown_device" }` 404
- [x] `POST /v1/license/resend`
  - [x] `email` で license を引いて Resend で再送 (同 email に複数 license があれば全部送る)
  - [x] **Rate limit 二段**: Cloudflare binding (IP 1分3回) + `rate_limit_log` (email 1分1回 / 1日5回)
  - [x] email enumeration 対策: 存在しない email でも 200 を返し、rate_limit_log は消費する
- [x] テスト用 license を `wrangler d1 execute --local` で seed して 13 シナリオの E2E 確認: activate × 3 → device_limit → re-activate (UPDATE) → deactivate → activate (空きで INSERT) → verify ok → verify unknown_device → wrong email (401) → invalid_credentials → resend noop → resend rate_limited → invalid_body (zod 400)

### Phase 3.5: 本番 deploy 前のレビュー反映 [AI🤖]
Phase 3 終了後の review で High 2 件 + Medium 2 件の指摘を受けたため、Phase 4 に進む前にここで潰す。

- [x] **wrangler.toml の env.production に全 binding を明示** (Wrangler v4 では env に binding が継承されない)。dev (top-level) と production (`[env.production]`) で同じ shape を二重に書く運用
- [x] **メール送信状態を `license.email_sent_at` に集約**。これまでは purchase_log.email_sent でしか管理しておらず、eventId が無い経路 (/thanks) でメール再送リスクがあった。`UPDATE ... WHERE email_sent_at IS NULL` の CAS で並列 safe
- [x] **`fulfillment_reject_log` を新規追加**。validateSession で reject されたケースを D1 監査 (Price ID 設定ミスや不正購入の早期検知用)
- [x] **Wrangler を v3.114 → v4.94 にアップグレード**、`[[unsafe.bindings]]` → `[[ratelimits]]` 正式構文へ移行
- [x] migration `0002_email_sent_at_and_reject_log.sql` を追加し、local D1 にも適用
- [x] 動作確認: `pnpm typecheck` / `pnpm test` (23 tests) / `wrangler dev --local` 起動 / `wrangler deploy --env production --dry-run` で全 binding が表示されることを確認

### Phase 4: LP + success_url ページ [AI🤖]
- [ ] `polepole.dev` の vanilla HTML + CSS で 1 ページ作成
  - [ ] タイトル / 1 文の価値提案 / スクリーンショット 1〜2 枚
  - [ ] 価格 (¥11,800 / Lifetime License) / Stripe Payment Link への購入ボタン
  - [ ] ダウンロードリンク (Cask + 直 DMG)
  - [ ] Zenn 詳細記事へのリンク
  - [ ] 利用規約 / プライバシーポリシー / 特商法表記へのリンク (フッター)
- [ ] `/thanks` ページ (Workers で session_id を受けて HTML を返す)
  - [ ] Phase 2 の `fulfillCheckout(sessionId, source="thanks_page")` を呼んで Stripe API で検証 + license 発行 (webhook 失敗時の保険)
  - [ ] D1 から license を引いてキー表示 + 「メールでも送りました」案内
  - [ ] fulfillment 失敗時の friendly エラー (上記)
  - [ ] アクティベート手順の説明
- [ ] `/legal/{terms,privacy,tokushoho}` の静的ページ
- [ ] Cloudflare Pages へデプロイ。`polepole.dev` を割り当て

### Phase 5前の準備 [人間👨‍💻]
- [ ] Stripe Payment Link を Test mode で作成 (¥11,800 / 円建て / success_url を `https://polepole.dev/thanks?session_id={CHECKOUT_SESSION_ID}` に設定)
- [ ] Stripe Test mode で test card で購入 → webhook が発火するか確認 → メールが届くか確認 → /thanks ページが正しく表示されるか確認

### Phase 5: アプリ側 - トライアル管理 [AI🤖]
- [x] `LicenseState` enum を定義 (`.trial(daysLeft: Int)` / `.activated(token: ActivationToken)` / `.trialExpired` / `.deactivated`)
- [x] `TrialManager` を新規実装
  - [x] Keychain に install date を書く / 読む (Service: `local.d0ne1s.polepole(.dev)`、Account: `trial-install-date`)
  - [x] `AppPaths.applicationSupportDirectory.appendingPathComponent("trial.json")` に install date を書く / 読む
  - [x] `installDate()` は両方を読んで min を返す。両方無ければ now() を書いて返す。片方しか無いときはもう片方に補完書きする
  - [x] `daysRemaining()` で残日数を返す
  - [x] `POLEPOLE_TEST_LICENSE_FAKE_NOW` (Unix 秒) で now() を上書きできるテストフック
- [x] アプリ起動時に `LicenseStore.shared` を初期化して `LicenseState` を確定 (`ContentView.onAppear` で `refreshFromDisk()`)
- [x] 期限切れ時に全 view をラップする `PaywallView` を実装 (購入画面 + キー入力フォーム + サポート/再送リンク)。`ContentView` の `ZStack` overlay として `state.isLocked` のときだけ最前面に重ねる
- [x] Settings に「ライセンス」タブを追加 (`LicenseSettingsView`、Shortcuts と並列の TabView)。キー入力フォーム + アクティベート済み時の情報表示 (Phase 6 で activate 経路を有効化) + deactivate ボタン (Phase 6)

### Phase 6: アプリ側 - アクティベーション + ローカル検証 [AI🤖]
- [x] `LicenseClient` を新規実装 (`activate` / `deactivate` / `verify` / `resend` を叩く)。baseURL は `POLEPOLE_BACKEND_URL` 環境変数で上書き、デフォルトは Debug=`http://127.0.0.1:8787` / Release=`https://api.polepole.dev`。エラーは `LicenseClientError` に正規化
- [x] `DeviceIdentifier` 実装 — `IOPlatformExpertDevice` UUID を取って SHA256 (64 hex)。`deviceName` / `osVersion` / `appVersion` のヘルパーも同居
- [x] `ActivationToken` のローカル保管 (`ActivationTokenStore`)
  - [x] Keychain に署名済みトークンを書く (Service: Bundle ID、Account: `activation-token`)
  - [x] EdDSA 公開鍵をアプリにバンドル (`Resources/License/license-pubkey.pem`、Phase 1 で配置済み)
  - [x] CryptoKit の `Curve25519.Signing.PublicKey` で署名検証 (`TokenVerifier`)。X.509 SPKI DER の prefix 12 bytes を剥がして raw 32 bytes を使う
  - [x] Keychain + Application Support の `token.json` で二重保存。片方しか無ければもう片方に補完書き
- [x] 起動時に Keychain/token.json から token を読み → 検証 → `LicenseState.activated` を確定
- [x] 週1の再検証スケジューラ (`LicenseStore.verifyIfNeeded()` を `ContentView.onAppear` で発火)
  - [x] verify 成功時: レスポンスの新しい署名トークンを `ActivationTokenStore.save` で上書き保存 (issued_at が更新される = 30 日 grace が自動延長)
  - [x] verify 失敗時 (一時的なネット切断 / rate limit): トークンは温存
  - [x] verify 失敗時 (server から revoked/refunded/unknown_device/invalid_credentials): トークンを clear し、トライアル経路に戻す
  - [x] ローカル検証で `issued_at + max_offline_days * 86400 < now()` なら `LicenseState.deactivated` に遷移
  - [x] 時計巻き戻し対策: Keychain に `last-observed-now` を Unix 秒で書き、判定時は `max(actualNow, lastObserved)` を使う (`monotonicNow`)
- [x] デバイス上限超過時のスワップダイアログ (`DeviceSwapSheet`)
  - [x] `activate` の `device_limit` レスポンスを受けて、既存デバイス一覧 (id / device_name / os_version / app_version / last_seen_at) を sheet で表示
  - [x] ユーザーが選んだ古いデバイスを `deactivate` → 即 `activate` リトライする `swapAndActivate(removing:)`
  - [x] PaywallView と LicenseSettingsView の両方から sheet を開く動線

### Phase 7: アプリ側 - 期限切れ / 起動ロック UX [AI🤖]
- [ ] `PaywallView` の見た目を整える
  - [ ] 「14 日間のトライアルが終了しました」 / 「ライセンスキーをお持ちの方」フォーム / 「購入する」ボタン (`polepole.dev` へリンク)
  - [ ] サポート問い合わせリンク (`support@polepole.dev`)
- [ ] 残日数 7 日以下からメニューバーに警告アイコン (静かなリマインド)
- [ ] 残日数 3 日以下から起動時に 1 回トーストでリマインド
- [ ] `ErrorBus.shared` で「ネットワークエラー時に再検証失敗、grace 残り N 日」を toast 表示

### Phase 8: メールテンプレ + 利用規約整備 [AI🤖 + 人間👨‍💻]
- [ ] [AI🤖] Resend 用のメールテンプレ (HTML / プレーンテキスト両方)
  - [ ] キー発行メール (購入直後)
  - [ ] キー再送メール
  - [ ] (将来用) サ終時 universal token 配信メール ひな型
- [ ] [人間👨‍💻] 利用規約 / プライバシーポリシー / 特商法表記の確定版を Phase 4 の `/legal/*` ページに流し込む
- [ ] [人間👨‍💻] 弁護士チェックを依頼するかの判断 (Stage1 は個人事業、雛形ベースでも可)

### Phase 9前の準備 [人間👨‍💻]
- [ ] Stripe を Live mode に切り替え、Payment Link を本番 ID で再発行
- [ ] Workers / Resend / DNS 周りを Live 用に切り替え
- [ ] サ終時用に EdDSA 秘密鍵を Dropbox dotfiles 配下に保管 (Sparkle 鍵と同じ運用)

### Phase 9: E2E テスト + 本番デプロイ [AI🤖 + 人間👨‍💻]
- [ ] [AI🤖] Stripe Test mode で End-to-End: 購入 → メール受信 → アクティベート → デバイス確認 → 別マシンで activate → 4 台目で上限超過ダイアログ確認
- [ ] [AI🤖] オフライン耐性: 認証成功後にネットワーク遮断 → 30 日経過シミュレーション (TimeMachine で時計を動かす or `POLEPOLE_TEST_LICENSE_FAKE_NOW` 環境変数を仕込む)
- [ ] [AI🤖] リファンドテスト: Stripe Dashboard で test mode の refund 実行 → アプリが次回 verify でロックされる
- [ ] [人間👨‍💻] 本番 Stripe で実カードで自己購入してフロー全体を確認 (¥11,800 自分払い)
- [ ] [人間👨‍💻] サポートメール受信確認 (`support@polepole.dev`)

### 動作確認 [人間👨‍💻]
- [ ] 新規 macOS ユーザーアカウントで PolePole.app を起動 → トライアル開始 → 14 日後ロックを `POLEPOLE_TEST_LICENSE_FAKE_NOW` で確認
- [ ] Keychain Access から install date を手で消した上で再起動 → Application Support 側の残骸で trial 残日数が復元されるか
- [ ] 期限切れ状態でアプリを起動 → PaywallView が全 view を覆っているか (メニュー・ターミナル・プレビュー全て不可)
- [ ] テスト購入 → メール受信 → Settings からアクティベート → 通常使用可能
- [ ] Wi-Fi 切断状態でアプリ起動 → ローカルトークンで起動可能 / 警告 toast が出る

## ログ

### 試したこと・わかったこと
- **2026-05-23 Phase 6 完了**: アプリ側アクティベーション + ローカル検証を実装
  - 新規ファイル 6 本: `DeviceIdentifier.swift` / `LicenseClient.swift` / `ActivationTokenStore.swift` / `TokenVerifier.swift` / `DeviceSwapSheet.swift` / (拡張) `LicenseStore.swift`
  - 設計の要: 起動時に Keychain → token.json → TokenVerifier (Ed25519) → `issued_at + 30 日` で activated/deactivated 判定。`POLEPOLE_TEST_LICENSE_FAKE_NOW` で時計を上書きできる
  - `monotonicNow()` で「観測した最大の現在時刻」を Keychain (`last-observed-now`) に積む = TimeMachine 等で時計を戻されてもローカル grace を巻き戻されない
  - E2E 動作確認: curl で activate → token を token.json に書く → アプリ起動 → `state = activated (expires in 30 days)` ログ + Paywall 非表示 / 同じ token + `POLEPOLE_TEST_LICENSE_FAKE_NOW=issued_at+31日` で起動 → `token expired ... -> deactivated` + Paywall 「ライセンスが無効化されました」表示
  - Backend は `pnpm dev` で local D1 + Workers が立ち、`/v1/license/activate` は 200 OK で署名済み token を返した。EdDSA 鍵ペア (Phase 1 で生成) のサーバ秘密鍵 ⇄ アプリ公開鍵の roundtrip が実環境で初通過
  - VERIFY.md に Section 35-E〜G を追加 (E: backend + curl + token.json → activated / F: grace 切れで deactivated / G: device_limit + DeviceSwapSheet)
- **2026-05-23 Phase 6 中の罠 (記録)**: アプリ起動経路で Keychain ダイアログが裏で待機して init が hang する事故
  - `security add-generic-password` コマンドで Keychain に書いた item をアプリから `SecItemCopyMatching` すると、アプリへのアクセス許可ダイアログが (時に裏側で) 出て、アプリ init が無限待機する
  - 同じく `launchctl setenv POLEPOLE_BACKEND_URL <url>` 経由で env を渡して `open -n` する経路でも、起動シーケンス上同様の hang を踏むことがあった
  - 回避策: 検証時は Keychain には直接書かず、token.json にだけ書く (アプリ初回 load で fallback として読み込まれ、補完書きで Keychain にも自動で書かれる)。env を渡したいときは direct exec (`POLEPOLE_BACKEND_URL=... "/path/to/PolePole Dev"`) を使う
  - これらは VERIFY.md 35-E に注意書きとして反映済み
- **2026-05-23 Phase 5 完了**: アプリ側トライアル管理を実装
  - `Sources/polepole/Licensing/` 配下に 6 ファイル新規追加: `KeychainHelper.swift` (Security framework の薄いラッパー) / `LicenseState.swift` (enum + ActivationToken Codable struct) / `TrialManager.swift` (Keychain + Application Support 二重管理 + POLEPOLE_TEST_LICENSE_FAKE_NOW フック) / `LicenseStore.swift` (@MainActor singleton、Phase 6 用に activate/deactivate stub) / `PaywallView.swift` (期限切れ時 overlay) / `LicenseSettingsView.swift` (Settings の License タブ)
  - `AppPaths.applicationSupportDirectory` を新規追加 (TrialManager と Phase 6 以降の Application Support 配置に集約)
  - `ContentView` を ZStack で wrap し、`LicenseStore.shared.state.isLocked` のときに PaywallView を最前面に重ねる構造に変更
  - Settings シーンを TabView 化し、Shortcuts + License の 2 タブに
  - Swift 6 strict concurrency: TrialManager は `@unchecked Sendable` で対応 (Logger と同じパターン、disk IO のみで shared mutable state は無い)
  - 動作確認: `mise run build` 成功 / 通常起動で `[license] state = trial(14 days left)` ログ + Paywall 非表示 / trial.json と Keychain の両方に同じ ISO8601 install date が書かれる / 片方消してももう片方から復元 / `POLEPOLE_TEST_LICENSE_FAKE_NOW=<install+15日>` で再起動すると `[license] state = trialExpired` ログ + Paywall がフルスクリーン overlay として表示
  - VERIFY.md に Section 35 (35-A〜D) を追加
- **2026-05-23 Phase 1 完了**: backend/ を初期化、Hono + TS + pnpm + D1 構成で動作確認まで通った
  - 構成: `backend/` (package.json / wrangler.toml / tsconfig / vitest config / src/ / migrations/ / scripts/ / test/)
  - 依存: hono 4.12 / zod 3.25 / wrangler 3.114 / vitest 2.1 / @cloudflare/workers-types
  - keygen テストで false positive バグ発見: `/[0O1Il]/` の `l` が `polepole-` プレフィックスの `l` に当たっていた → ランダム部分だけチェックする regex に修正
  - wrangler ローカル起動の `unsafe.bindings` rate-limit は experimental 警告が出るが Miniflare 上で動作
  - compatibility_date `2026-05-23` はローカルランタイムが未追随で `2025-07-18` にフォールバック (機能差分の警告のみ、動作には影響なし)
- **2026-05-23 Stripe Sandbox セットアップ自動化**: `backend/scripts/setup-stripe-products.sh` を作成
  - Stripe CLI 経由で Product (`PolePole Lifetime License`) / Price (¥11,800 JPY) / Payment Link (card-only + redirect to thanks page) を一括作成
  - `sk_live_*` を弾くセーフガード入り (Sandbox 限定で動かす)
  - 既存 Stripe アカウント (`d0ne1s`) 配下に `PolePole Stage1` Sandbox を切って、その中で実行
- **2026-05-23 EdDSA 署名のラウンドトリップ確認**: `test/signing.test.ts` で「秘密鍵で署名 → 公開鍵で検証」が通ることを実鍵で検証
  - `.dev.vars` 経由で渡される `\n` エスケープ済み PEM 形式と、生 PEM の両方をカバー
  - これにより Phase 2 で `issueToken` を本格的に使う前に、署名チェーンの健全性を担保
- **2026-05-23 Phase 3.5 (レビュー反映)**: 本番 deploy 前に潰した 4 件
  - Wrangler v4 + 正式 `[[ratelimits]]` 構文へ移行 → `local` モードで rate limit が emulation され、テスト時の binding rate limit 詰まり問題も自然解消の見込み
  - メール idempotency を `license.email_sent_at` (CAS UPDATE) に集約 → /thanks と webhook の二重送信問題が解消
  - reject ログを `fulfillment_reject_log` に切り出し、Price ID 設定ミス等を D1 で監査可能に
  - `[env.production]` で全 binding (DB / ratelimits / vars) を明示 → dry-run で本番 binding が確実に見える
- **2026-05-23 Phase 3 完了**: activate / deactivate / verify / resend
  - デバイス上限 3 を D1 batch (UPDATE + INSERT-WHERE-NOT-EXISTS-AND-COUNT + SELECT) で atomic に処理。並列リクエストでも 4 台目がすり抜けない
  - verify は成功時に必ず新トークンを発行 → アプリ側 Keychain 上書きで grace 自動延長 (短寿命トークンの自然延長設計)
  - Rate limit 二段: Cloudflare binding (IP 早期遮断) + D1 `rate_limit_log` (email 細粒度)
  - resend.ts に bug: `.dev.vars` の `RESEND_API_KEY` を Python 書き換え時に置換し忘れて example の `re_xxxxxxxx` が残っていた → guard `startsWith("re_placeholder")` がマッチせず実 Resend API に到達して 401 取得。`.dev.vars.example` の placeholder を `re_placeholder_set_later` に統一 + guard を `includes("placeholder")` に緩めて修正
  - ローカル開発時の binding rate limit は `unsafe.bindings` が remote resource に当たって連続テストを邪魔する → Phase 4 以降で local bypass を検討
- **2026-05-23 Phase 2 完了**: fulfillCheckout + /stripe-webhook + /thanks
  - stripe-node SDK は使わず fetch ラッパー (`src/lib/stripe.ts`) で書いた。bundle size 軽い & Workers ネイティブ
  - `validateSession` を pure 関数に切り出して 12 ケースの単体テストでカバー (購入条件のすべての rejection パターン)
  - Stripe webhook 署名検証も pure ロジックで 6 ケースカバー (HMAC-SHA256 / multi-v1 / 5 分 tolerance / tampered / wrong secret / malformed)
  - D1 統合テストは敢えて書かず、Phase 9 の E2E (Stripe CLI で実 webhook + 実 test card) で確認する方針
  - 動作確認: wrangler dev で全ルート疎通。特に `/thanks?session_id=cs_test_nonexistent_42` で実 Sandbox API に到達して 404 取得 = `.dev.vars` の sk_test_... が正しく動いていることを確認

### 教訓 (AI セッションでの secret 取扱)
- **AI セッション経由で秘密鍵を扱うときは、stdout / 中間出力 / sanity check にも値が流れないよう注意する**。今回 2 回、EdDSA 秘密鍵の本体が会話に漏れた (Sandbox 用なので実害なし、再生成済み)
- 根本原因:
  1. `awk -F= '/^[A-Z]/{...}' .dev.vars` で sanity check した時、multi-line 値の 2 行目以降 (Base64 で先頭が大文字英字) が新しい KEY として認識されて出力された
  2. Python の `re.sub` の repl 引数は `\n` 等のエスケープを再解釈する仕様。文字列 repl ではなく **callable repl** (`lambda _m, v=value: f'{key}="{v}"'`) で回避する必要があった
  3. macOS の BSD sed も置換側の `\n` を改行に変換する。bash → sed の経路で multi-line PEM を扱うのは複雑
- 対策ルール:
  - secret を `.dev.vars` に投入する処理は **Python + callable repl** で固定 (sed / awk は使わない)
  - sanity check は「値は一切出さず、行数 + 単一行性 + ダブルクオート対称性」だけを確認する
  - **本番運用に使う EdDSA 鍵は Phase 9 直前に人間が手動で生成**し、AI セッションには一切流さない (Sandbox 用とは別鍵)

### 方針変更
- **2026-05-23 Phase 1 着手時**: `polepole-backend/` を別 repo にする案 → **monorepo (本 repo 内 `backend/`) に変更**。理由: PolePole 本体もクローズド配布なので別 repo にする強い理由が薄い / セッション切り替え不要 / git log・CI・mise 設定を共有できて運用が軽い。将来 OSS 化や権限分離が必要になったら切り出す
- **2026-05-23** plan 初版へのレビュー指摘 7 件を反映:
  - 鍵の役割を逆に書いていた → Workers env=秘密鍵 / アプリ=公開鍵に修正
  - `issued_at + 30 日` 失効と週1 verify が矛盾 → verify 成功時に新トークンを発行 → アプリで上書きする設計に統一 (短寿命トークン + 自動延長)
  - `/thanks` の保険を「D1 から引くだけ」と書いていた → Stripe API で session 検証 + 共通 fulfillment 関数を呼ぶ設計に変更
  - webhook 検証条件を粗く書いていた → `payment_status` / `amount_total` / `currency` / `Price ID` / `Payment Link ID` の一致を明示、遅延決済は Payment Link 側で card 限定にして無視
  - appcast R2 統合を前提に書いていた → 既存 Sparkle feed への影響範囲が大きいため別 plan に切り出し、本 plan の範囲外として明記
  - device 上限の count→insert が並列で破綻し得る → D1 batch / 単一クエリで原子化する方針を明記
  - rate limit の保存先が無かった → Cloudflare Rate Limiting binding + `rate_limit_log` テーブルで補強する二段構えに
