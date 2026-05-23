# polepole-backend

PolePole の決済・ライセンス基盤 (Cloudflare Workers + D1)。設計の根拠は [`docs/plans/2026-05-23-payment-and-licensing.md`](../docs/plans/2026-05-23-payment-and-licensing.md) を参照。

## 依存

- pnpm (mise 経由で OK)
- openssl (Ed25519 鍵生成)
- Cloudflare アカウント (deploy 時のみ)

## セットアップ

```bash
pnpm install
pnpm keys:generate        # Ed25519 鍵生成 (秘密鍵=dotfiles / 公開鍵=Resources/License/)
cp .dev.vars.example .dev.vars
$EDITOR .dev.vars         # Stripe / Resend / EdDSA 秘密鍵を埋める
pnpm db:migrate:local     # ローカル D1 (SQLite) にスキーマ適用
```

## 開発

```bash
pnpm dev                  # wrangler dev --local。http://localhost:8787
pnpm test                 # vitest (Phase 1 は sanity のみ)
pnpm typecheck            # tsc --noEmit
```

## デプロイ (本番)

事前準備:
1. `wrangler d1 create polepole-licenses` で本番 D1 を作成し、`wrangler.toml` の `database_id` を差し替え
2. `pnpm wrangler secret put LICENSE_SIGNING_PRIVATE_KEY < $DOTFILES_DIR/secrets/polepole/license-signing-private.pem`
3. `pnpm wrangler secret put STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` / `RESEND_API_KEY`
4. `pnpm db:migrate:remote`
5. `pnpm deploy`

## エンドポイント

| Path | Method | Phase | 用途 |
|---|---|---|---|
| `/healthz` | GET | 1 | liveness probe |
| `/stripe-webhook` | POST | 2 | Stripe webhook → `fulfillCheckout(session.id, "webhook")` |
| `/thanks` | GET | 2 | Stripe success_url → `fulfillCheckout(session.id, "thanks_page")` + キー表示 |
| `/v1/license/activate` | POST | 3 | 初回アクティベート / 署名トークン発行 |
| `/v1/license/deactivate` | POST | 3 | デバイス抹消 |
| `/v1/license/verify` | POST | 3 | 週1再検証 (成功時に新トークン返却で grace 自動延長) |
| `/v1/license/resend` | POST | 3 | キー再送 (rate-limit 二段) |

## 設計の不変条件 (絶対に守る)

- アプリ側のライセンス検証は **決済プロバイダ非依存**。Stripe → Paddle 移行を 2-3 日で済ますためのオプション保有。理由は [`docs/COMMERCIALIZATION.md`](../docs/COMMERCIALIZATION.md) の「Stripe → Paddle 移行のコスト見積もり」節を参照
- EdDSA **秘密鍵は Workers env のみ**。アプリには公開鍵だけバンドル
- `fulfillCheckout` は **idempotent** (webhook と /thanks の両方から呼ばれる前提で重複に強い)
- デバイス上限の `count → insert` は **D1 batch / 単一クエリで原子化**。別クエリで実装してはいけない
