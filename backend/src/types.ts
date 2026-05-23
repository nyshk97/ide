// Cloudflare Workers の bindings 型。wrangler.toml と一致させる。

export type RateLimit = {
  limit: (opts: { key: string }) => Promise<{ success: boolean }>;
};

export type Bindings = {
  DB: D1Database;
  RATE_LIMITER_ACTIVATE: RateLimit;
  RATE_LIMITER_RESEND: RateLimit;

  EXPECTED_AMOUNT: string;
  EXPECTED_CURRENCY: string;
  EXPECTED_PRICE_ID: string;
  EXPECTED_PAYMENT_LINK_ID: string;
  RESEND_ENABLED: string;

  // secrets (wrangler secret put で投入)
  STRIPE_SECRET_KEY?: string;
  STRIPE_WEBHOOK_SECRET?: string;
  RESEND_API_KEY?: string;
  LICENSE_SIGNING_PRIVATE_KEY?: string;
};

export type License = {
  id: string;
  email: string;
  stripe_session_id: string;
  stripe_payment_intent_id: string | null;
  amount: number;
  currency: string;
  status: "active" | "revoked" | "refunded";
  created_at: number;
  updated_at: number;
};

export type Device = {
  id: string;
  license_id: string;
  device_hash: string;
  device_name: string | null;
  os_version: string | null;
  app_version: string | null;
  activated_at: number;
  last_seen_at: number;
};

export const DEVICE_LIMIT = 3;
export const TOKEN_MAX_OFFLINE_DAYS = 30;
