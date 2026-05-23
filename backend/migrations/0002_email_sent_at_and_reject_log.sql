-- メール送信状態を license 自身に持たせる。
-- これまでは purchase_log.email_sent でしか管理しておらず、eventId が無い経路 (/thanks)
-- ではメール再送リスクがあった。`license.email_sent_at` を idempotency の単一の真理値にする。
ALTER TABLE license ADD COLUMN email_sent_at INTEGER;

-- fulfillment_reject_log: validateSession で拒否された購入の監査ログ。
-- purchase_log は「成功した event を idempotent に処理する」用、こちらは「拒否された経緯」用。
-- Price ID 設定ミスや不正購入の検知に使う。
CREATE TABLE fulfillment_reject_log (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  stripe_session_id TEXT NOT NULL,
  stripe_event_id   TEXT,
  source            TEXT NOT NULL,
  reason            TEXT NOT NULL,
  payload           TEXT NOT NULL,
  occurred_at       INTEGER NOT NULL
);

CREATE INDEX idx_fulfillment_reject_log_session ON fulfillment_reject_log(stripe_session_id);
CREATE INDEX idx_fulfillment_reject_log_occurred ON fulfillment_reject_log(occurred_at);
