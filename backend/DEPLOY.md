# PolePole Backend — 本番デプロイ手順

`backend/` を Cloudflare Workers の `polepole.dev` (本番) にデプロイする手順。
Phase 9 C の人間タスクをチェックリスト形式で並べたもの。AI セッションでは
secret 値を扱わないため、ターミナルで人間が直接実行する想定。

設計の根拠と背景: [docs/plans/2026-05-23-payment-and-licensing.md](../docs/plans/2026-05-23-payment-and-licensing.md)

---

## 0. 完了済み (Phase 9 C-1〜C-5)

- [x] 本番 D1 作成 — `polepole-licenses-prod` / region APAC / `database_id = 291d3fd4-3a52-4fc3-a60d-edff2d94473a` (`wrangler.toml` の `[env.production.d1_databases]` 参照)
- [x] 本番 D1 マイグレーション適用 — `wrangler d1 migrations apply polepole-licenses-prod --remote --env production` で 0001 + 0002 適用済
- [x] `wrangler.toml` の `[env.production].routes` に `polepole.dev/*` を追加
- [x] アプリ側 LicenseClient の Release ビルド baseURL を `https://polepole.dev` に統合 (subdomain `api.polepole.dev` を廃止)
- [x] `wrangler deploy --env production --dry-run` で binding 確認 (D1 / Rate Limiter / vars)

---

## 1. 本番 EdDSA 鍵ペアの再生成 [人間タスク]

> **重要**: 本番秘密鍵は AI セッションに流さない。ターミナルで直接実行する。Sandbox 用 (`backend/.dev.vars`) とは別の鍵を使うこと。

```bash
cd backend
# 1) 鍵を生成 (PEM 出力)
openssl genpkey -algorithm ed25519 -out /tmp/polepole-prod-priv.pem
openssl pkey -in /tmp/polepole-prod-priv.pem -pubout -out /tmp/polepole-prod-pub.pem

# 2) 秘密鍵を Workers の本番 secret に投入
pnpm exec wrangler secret put LICENSE_SIGNING_PRIVATE_KEY --env production < /tmp/polepole-prod-priv.pem

# 3) サ終時 universal token 用にバックアップ (Sparkle 鍵と同じ運用)
mkdir -p ~/Library/CloudStorage/Dropbox/dotfiles/secrets/polepole
cp /tmp/polepole-prod-priv.pem ~/Library/CloudStorage/Dropbox/dotfiles/secrets/polepole/license-signing-prod-priv.pem
chmod 600 ~/Library/CloudStorage/Dropbox/dotfiles/secrets/polepole/license-signing-prod-priv.pem

# 4) 公開鍵をアプリにバンドル (Sandbox 用と差し替え)
cp /tmp/polepole-prod-pub.pem ../Resources/License/license-pubkey.pem

# 5) /tmp の生鍵を消す (Dropbox に控えがあるので OK)
rm -f /tmp/polepole-prod-priv.pem /tmp/polepole-prod-pub.pem
```

`Resources/License/license-pubkey.pem` を変更したらアプリの rebuild が必要。

---

## 2. Stripe Live mode へ切替 [人間タスク]

### 2.1 Live mode の Product / Price / Payment Link 作成

```bash
# Stripe Dashboard を Live mode に切替 (上部の Test mode トグルを OFF)
# Dashboard > Developers > API keys から sk_live_... を取得

export STRIPE_SK_LIVE=sk_live_xxxxxxxx
bash backend/scripts/setup-stripe-products.sh
# (スクリプトは sk_live_ を弾くガードを sk_test_ 限定で書いてある。Live 用に
#  一行コメントアウトするか、Dashboard で手動作成しても OK)
```

### 2.2 Webhook endpoint 作成

Stripe Dashboard > Developers > Webhooks > Add endpoint:
- **URL**: `https://polepole.dev/stripe-webhook`
- **Events**: `checkout.session.completed`, `refund.created`, `charge.refunded`
- 作成後の `Signing secret` (`whsec_...`) をコピー

### 2.3 Live 用 secret を Workers に投入

```bash
cd backend
echo "<sk_live_...>"   | pnpm exec wrangler secret put STRIPE_SECRET_KEY     --env production
echo "<whsec_...>"     | pnpm exec wrangler secret put STRIPE_WEBHOOK_SECRET --env production
echo "<price_...>"     | pnpm exec wrangler secret put EXPECTED_PRICE_ID    --env production
echo "<plink_...>"     | pnpm exec wrangler secret put EXPECTED_PAYMENT_LINK_ID --env production
```

---

## 3. Resend ドメイン認証 [人間タスク]

1. Resend Dashboard > Domains > Add Domain → `polepole.dev`
2. 表示される SPF / DKIM レコード (TXT) を Cloudflare DNS に追加
3. Cloudflare Dashboard > DNS > Add record で TXT レコードをコピペ
4. Resend Dashboard で "Verify" を押して緑になるのを待つ (数分)
5. Resend Dashboard > API Keys から本番 API key を作成
6. Workers に投入:

```bash
echo "<re_live_...>" | pnpm exec wrangler secret put RESEND_API_KEY --env production
```

---

## 4. polepole.dev DNS を Cloudflare に [人間タスク]

1. ドメインレジストラ (Squarespace / Cloudflare Registrar 等) で `polepole.dev` の NS レコードを Cloudflare のものに変更
2. Cloudflare Dashboard > polepole.dev zone > DNS で apex `polepole.dev` に Workers route が当たるよう設定
   - Cloudflare の自動検知でも当たることが多い (wrangler.toml の `routes` 設定済み)
   - 必要なら `AAAA polepole.dev 100::` の "Proxy: Yes" レコードを追加 (Cloudflare workers proxy)
3. SSL/TLS > Edge Certificates で `polepole.dev` の証明書が active になっているか確認

DNS 反映には最大 24h かかる可能性。`dig polepole.dev` で NS と A/AAAA が Cloudflare に向いているか確認。

---

## 5. 本番デプロイ [認可後 AI が実行 or 人間タスク]

すべての secret + DNS 設定完了後:

```bash
cd backend
pnpm exec wrangler deploy --env production
```

成功すると `https://polepole.dev/` の応答が変わる。dry-run と異なり、実 zone に route が設定される。

---

## 6. Smoke test [AI で実行可能]

```bash
# LP
curl -s -o /dev/null -w "GET / -> %{http_code}\n" https://polepole.dev/
# 法的ページ
for path in /legal/terms /legal/privacy /legal/tokushoho; do
  curl -s -o /dev/null -w "GET $path -> %{http_code}\n" "https://polepole.dev$path"
done
# 動的ルート (param なしで 400 / 405 等が返れば疎通 OK)
curl -s -o /dev/null -w "GET /healthz -> %{http_code}\n" https://polepole.dev/healthz
curl -s -o /dev/null -w "GET /thanks -> %{http_code}\n"  https://polepole.dev/thanks
# Stripe webhook 受信 (POST のみ、空 body で 400 想定)
curl -s -o /dev/null -w "POST /stripe-webhook -> %{http_code}\n" -X POST https://polepole.dev/stripe-webhook
```

期待: `/` `/styles.css` `/legal/*` `/healthz` は 200、`/thanks` は 400 (session_id 必須)、`/stripe-webhook` は 400 (署名検証失敗)。

---

## 7. アプリ Release ビルド + Sparkle 配信 [認可後 AI が実行 or 人間タスク]

```bash
# repo root
./scripts/release.sh
```

`scripts/release.sh` の内容: project.yml の MARKETING_VERSION 確認 → xcodebuild archive → notarize → ditto で zip → nyshk97/polepole-releases に upload → appcast.xml 更新 → nyshk97/homebrew-tap の cask を bump → 各 push。

詳細は `scripts/release.sh` のコメントとログを参照。

---

## 8. 本番購入で最終確認 [人間タスク]

1. Safari で `https://polepole.dev/` を開く → 「購入する」ボタン
2. Stripe Payment Link で実カード (本人) で ¥11,800 払い (返金可なので動作確認用)
3. `https://polepole.dev/thanks?session_id=...` でキー表示
4. `nyshk97@gmail.com` (購入時メアド) にキー発行メールが届く
5. アプリで Settings > ライセンス → メアドとキー入力 → activated になる
6. 必要なら Stripe Dashboard で refund 実行 → アプリで verify reject → トライアル経路復帰

---

## チェックリスト (人間タスク全体)

- [ ] 1. 本番 EdDSA 鍵ペア再生成 + 公開鍵を `Resources/License/license-pubkey.pem` に上書き + アプリ rebuild
- [ ] 2.1 Stripe Live mode で Product / Price / Payment Link 作成
- [ ] 2.2 Webhook endpoint 作成 (`https://polepole.dev/stripe-webhook`)
- [ ] 2.3 Live 用 secret 4 件投入 (STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET / EXPECTED_PRICE_ID / EXPECTED_PAYMENT_LINK_ID)
- [ ] 3. Resend で `polepole.dev` ドメイン認証 + RESEND_API_KEY 投入
- [ ] 4. `polepole.dev` の DNS を Cloudflare に向ける + Edge cert active
- [ ] 5. `pnpm exec wrangler deploy --env production` 実行
- [ ] 6. Smoke test (curl)
- [ ] 7. アプリ Release ビルド + Sparkle 配信 (`./scripts/release.sh`)
- [ ] 8. 本番購入 → activate → サポートメール確認

すべて green になったら v1.0 launch。

---

## 付録: Stripe 操作の落とし穴 (2026-05-24 実地検証)

### A. Promotion Code 作成時の API version 必須

新版 Stripe API (Default Version、概ね 2024 年後半以降) では `POST /v1/promotion_codes` の `coupon` パラメータが `parameter_unknown` で reject される (確認: 2026-05-24 時点)。古い header を明示すれば動く。

```bash
# NG (新版 default だと unknown parameter)
curl -X POST -u "$SK:" https://api.stripe.com/v1/promotion_codes -d coupon=...

# OK
curl -X POST -u "$SK:" -H "Stripe-Version: 2024-06-20" \
  https://api.stripe.com/v1/promotion_codes -d coupon=...
```

`coupons` の作成や `payment_links` 作成・update では発生しない (`promotion_codes` 固有)。

### B. stripe CLI の `retrieve / update / delete` が pipe で hang

`stripe webhook_endpoints retrieve`, `update`, `delete` 等を `>` redirect / `tee` / `$(...)` で受けると hang or 空出力で返ってくる (stripe CLI v1.41 系)。`create` 系は redirect でも OK。CLI で取得できない値 (例: 既存 endpoint の signing secret 等) は **curl で `https://api.stripe.com/v1/...` を直接叩く**こと。

### C. AI 自動入力で Stripe Checkout は突破不可

agent-browser 等で test card を自動入力 + submit すると Stripe の **Agentic Commerce Protocol の Agent Disclosure** (Agent Identity Token = Verifiable Credential 要求) が発火して支払いに進めない。E2E テストでは **人間が手で「支払う」を押す**運用にする。代わりに API 経路 (`stripe webhook_endpoints create` / `stripe payment_links update` 等) は自動化できる。

### D. Stripe Checkout の `amount_total` 厳密チェックはクーポンと両立しない

`validateSession` で `session.amount_total === EXPECTED_AMOUNT` の厳密比較を行うと、Promotion Code 適用時に amount が減額 (100% off → 0、50% off → 5900) されて `amount_mismatch` で reject される。商品の正当性は `EXPECTED_PRICE_ID` + `EXPECTED_PAYMENT_LINK_ID` + Stripe 署名検証で担保するので amount 値の比較は不要。`amount_total === null || < 0` だけ defense-in-depth として残す。
