// 購入完了 (Stripe checkout.session.completed) の fulfillment 処理。
// webhook と /thanks の両方からこの関数を呼ぶことで、片方の経路がコケても救える。
//
// 全ステップ idempotent:
// - license は stripe_session_id UNIQUE で重複防止
// - purchase_log は stripe_event_id UNIQUE で重複防止
// - メール送信は purchase_log.email_sent フラグで二重送信防止

import type { Bindings, License } from "../types";
import { generateLicenseKey } from "./keygen";
import { retrieveCheckoutSession, type StripeCheckoutSession } from "./stripe";
import { sendEmail } from "./resend";
import { buildLicenseKeyEmail } from "./email-templates";

export type FulfillRejection =
  | "not_paid"
  | "amount_mismatch"
  | "currency_mismatch"
  | "price_mismatch"
  | "payment_link_mismatch"
  | "no_email";

export type FulfillResult =
  | { status: "fulfilled"; license: License; created: boolean; emailSent: boolean }
  | { status: "rejected"; reason: FulfillRejection };

export type FulfillSource = "webhook" | "thanks_page" | "manual";

export type ValidationEnv = {
  EXPECTED_AMOUNT: string;
  EXPECTED_CURRENCY: string;
  EXPECTED_PRICE_ID: string;
  EXPECTED_PAYMENT_LINK_ID: string;
};

export type ValidatedSession = {
  email: string;
  amount: number;
  currency: string;
  paymentIntentId: string | null;
};

// 検証ロジックだけ pure に切り出してテスト可能にする。
export function validateSession(
  session: StripeCheckoutSession,
  env: ValidationEnv
): { ok: true; data: ValidatedSession } | { ok: false; reason: FulfillRejection } {
  if (session.payment_status !== "paid") return { ok: false, reason: "not_paid" };
  // amount_total は Promotion Code (クーポン) 適用時に減額されるため厳密一致チェックは外す。
  // 商品の正当性は EXPECTED_PRICE_ID と EXPECTED_PAYMENT_LINK_ID + Stripe 署名検証で担保。
  // amount_total < 0 だけ最低限弾く (Stripe 仕様上ありえないが defense-in-depth)。
  if (session.amount_total === null || session.amount_total < 0)
    return { ok: false, reason: "amount_mismatch" };
  if (session.currency?.toLowerCase() !== env.EXPECTED_CURRENCY.toLowerCase())
    return { ok: false, reason: "currency_mismatch" };

  const priceIds = (session.line_items?.data ?? [])
    .map((li) => li.price?.id)
    .filter((x): x is string => !!x);
  if (!priceIds.includes(env.EXPECTED_PRICE_ID)) return { ok: false, reason: "price_mismatch" };
  if (session.payment_link !== env.EXPECTED_PAYMENT_LINK_ID)
    return { ok: false, reason: "payment_link_mismatch" };

  const email = session.customer_details?.email;
  if (!email) return { ok: false, reason: "no_email" };

  return {
    ok: true,
    data: {
      email,
      amount: session.amount_total!,
      currency: session.currency!,
      paymentIntentId: session.payment_intent,
    },
  };
}

export async function fulfillCheckout(
  env: Bindings,
  sessionId: string,
  source: FulfillSource,
  eventId?: string
): Promise<FulfillResult> {
  if (!env.STRIPE_SECRET_KEY) throw new Error("STRIPE_SECRET_KEY is not set");

  // 1. Stripe API で session を再取得 (webhook payload は信用しない)
  const session = await retrieveCheckoutSession(env.STRIPE_SECRET_KEY, sessionId);
  const now = Math.floor(Date.now() / 1000);

  // 2. 検証条件を全部チェック (pure 関数で testable)
  const v = validateSession(session, env);
  if (!v.ok) {
    // 拒否は監査記録する (Price ID 設定ミスや不正購入の早期検知)
    await recordRejection(env, {
      sessionId,
      eventId,
      source,
      reason: v.reason,
      payload: session,
      now,
    });
    return { status: "rejected", reason: v.reason };
  }
  const { email, amount, currency, paymentIntentId } = v.data;

  // 3. license の idempotent 作成
  const { license, created } = await upsertLicense(env, {
    sessionId,
    paymentIntentId,
    email,
    amount,
    currency,
    now,
  });

  // 4. purchase_log: webhook 経由 (event_id あり) のみ記録 (event の重複処理を防ぐ)
  if (eventId) {
    await env.DB.prepare(
      `INSERT INTO purchase_log
         (event_type, stripe_event_id, stripe_session_id, source, email_sent, payload, received_at)
       VALUES (?, ?, ?, ?, 0, ?, ?)
       ON CONFLICT (stripe_event_id) DO NOTHING`
    )
      .bind(
        "checkout.session.completed",
        eventId,
        sessionId,
        source,
        JSON.stringify(session),
        now
      )
      .run();
  }

  // 5. メール送信 (idempotency は license.email_sent_at で集約管理)
  //   /thanks 経由 (eventId なし) でも webhook 経由 (eventId あり) でも、
  //   license.email_sent_at IS NULL なら送り、成功時に CAS で更新する。
  //   失敗時は email_sent_at が NULL のままなので、再送 endpoint や次回の経路で救済可能。
  const emailSent = await sendEmailIfNotYet(env, license);

  return { status: "fulfilled", license, created, emailSent };
}

async function sendEmailIfNotYet(env: Bindings, license: License): Promise<boolean> {
  if (license.email_sent_at !== null) return true;
  try {
    await sendEmail(
      env.RESEND_API_KEY,
      env.RESEND_ENABLED === "true",
      buildLicenseKeyEmail(license)
    );
  } catch (err) {
    console.error("email send failed:", err);
    return false;
  }
  // CAS: email_sent_at が NULL のときだけ書き込む。並列で他のリクエストが先に書いたら
  // 自分の UPDATE は 0 行になるが、いずれにせよ送信は成功している扱いで OK。
  await env.DB.prepare(
    "UPDATE license SET email_sent_at = ? WHERE id = ? AND email_sent_at IS NULL"
  )
    .bind(Math.floor(Date.now() / 1000), license.id)
    .run();
  return true;
}

async function recordRejection(
  env: Bindings,
  args: {
    sessionId: string;
    eventId: string | undefined;
    source: FulfillSource;
    reason: FulfillRejection;
    payload: unknown;
    now: number;
  }
): Promise<void> {
  try {
    await env.DB.prepare(
      `INSERT INTO fulfillment_reject_log
         (stripe_session_id, stripe_event_id, source, reason, payload, occurred_at)
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(
        args.sessionId,
        args.eventId ?? null,
        args.source,
        args.reason,
        JSON.stringify(args.payload),
        args.now
      )
      .run();
  } catch (err) {
    // 監査ログの失敗で fulfillment 自体を落とさない
    console.error("reject log failed:", err);
  }
}

async function upsertLicense(
  env: Bindings,
  args: {
    sessionId: string;
    paymentIntentId: string | null;
    email: string;
    amount: number;
    currency: string;
    now: number;
  }
): Promise<{ license: License; created: boolean }> {
  const existing = await env.DB.prepare(
    "SELECT * FROM license WHERE stripe_session_id = ?"
  )
    .bind(args.sessionId)
    .first<License>();
  if (existing) return { license: existing, created: false };

  const id = generateLicenseKey();
  await env.DB.prepare(
    `INSERT INTO license
       (id, email, stripe_session_id, stripe_payment_intent_id, amount, currency, status, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)
     ON CONFLICT (stripe_session_id) DO NOTHING`
  )
    .bind(
      id,
      args.email,
      args.sessionId,
      args.paymentIntentId,
      args.amount,
      args.currency,
      args.now,
      args.now
    )
    .run();

  // ON CONFLICT で何も入らなかった場合は他のリクエストが INSERT 済み
  const license = await env.DB.prepare(
    "SELECT * FROM license WHERE stripe_session_id = ?"
  )
    .bind(args.sessionId)
    .first<License>();
  if (!license) throw new Error("license insert failed and SELECT returned nothing");
  // created 判定: insert 直後の SELECT で id 一致なら自分が作った
  return { license, created: license.id === id };
}

// refund.created / charge.refunded を受けて license.status を 'refunded' に。
export async function markRefunded(
  env: Bindings,
  paymentIntentId: string
): Promise<{ updated: number }> {
  const now = Math.floor(Date.now() / 1000);
  const result = await env.DB.prepare(
    `UPDATE license SET status = 'refunded', updated_at = ?
     WHERE stripe_payment_intent_id = ? AND status = 'active'`
  )
    .bind(now, paymentIntentId)
    .run();
  return { updated: result.meta?.changes ?? 0 };
}
