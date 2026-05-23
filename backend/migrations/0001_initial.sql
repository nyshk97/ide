-- 初期スキーマ。
-- 設計詳細は docs/plans/2026-05-23-payment-and-licensing.md の「DB スキーマ」を参照。

-- license: 購入 1 件 = 1 行
CREATE TABLE license (
  id                        TEXT PRIMARY KEY,
  email                     TEXT NOT NULL,
  stripe_session_id         TEXT NOT NULL UNIQUE,
  stripe_payment_intent_id  TEXT,
  amount                    INTEGER NOT NULL,
  currency                  TEXT NOT NULL,
  status                    TEXT NOT NULL CHECK (status IN ('active', 'revoked', 'refunded')),
  created_at                INTEGER NOT NULL,
  updated_at                INTEGER NOT NULL
);

CREATE INDEX idx_license_email ON license(email);

-- device: ライセンスに紐付くデバイス (上限 3)
CREATE TABLE device (
  id              TEXT PRIMARY KEY,
  license_id      TEXT NOT NULL REFERENCES license(id) ON DELETE CASCADE,
  device_hash     TEXT NOT NULL,
  device_name     TEXT,
  os_version      TEXT,
  app_version     TEXT,
  activated_at    INTEGER NOT NULL,
  last_seen_at    INTEGER NOT NULL,
  UNIQUE(license_id, device_hash)
);

CREATE INDEX idx_device_license ON device(license_id);

-- purchase_log: webhook / thanks_page 受信履歴 (idempotent fulfillment & 監査用)
CREATE TABLE purchase_log (
  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
  event_type          TEXT NOT NULL,
  stripe_event_id     TEXT NOT NULL UNIQUE,
  stripe_session_id   TEXT,
  source              TEXT NOT NULL CHECK (source IN ('webhook', 'thanks_page', 'manual')),
  email_sent          INTEGER NOT NULL DEFAULT 0,
  payload             TEXT NOT NULL,
  received_at         INTEGER NOT NULL
);

CREATE INDEX idx_purchase_log_session ON purchase_log(stripe_session_id);

-- rate_limit_log: email ベース等、Cloudflare Rate Limiting で取れない粒度の補強
CREATE TABLE rate_limit_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  key           TEXT NOT NULL,
  occurred_at   INTEGER NOT NULL
);

CREATE INDEX idx_rate_limit_log_key_time ON rate_limit_log(key, occurred_at);
