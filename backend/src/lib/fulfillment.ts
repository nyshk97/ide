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
import { sendEmail, type ResendEmail } from "./resend";

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
  if (session.amount_total !== Number(env.EXPECTED_AMOUNT))
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

  // 2. 検証条件を全部チェック (pure 関数で testable)
  const v = validateSession(session, env);
  if (!v.ok) return { status: "rejected", reason: v.reason };
  const { email, amount, currency, paymentIntentId } = v.data;

  const now = Math.floor(Date.now() / 1000);

  // 3. license の idempotent 作成
  const { license, created } = await upsertLicense(env, {
    sessionId,
    paymentIntentId,
    email,
    amount,
    currency,
    now,
  });

  // 4. purchase_log: webhook 経由 (event_id あり) のみ記録
  let emailAlreadySent = false;
  if (eventId) {
    const existing = await env.DB.prepare(
      "SELECT email_sent FROM purchase_log WHERE stripe_event_id = ?"
    )
      .bind(eventId)
      .first<{ email_sent: number }>();
    if (existing) {
      emailAlreadySent = existing.email_sent === 1;
    } else {
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
  }

  // 5. メール送信 (idempotent。失敗しても license は発行済み、再送 endpoint で救済可能)
  let emailSent = emailAlreadySent;
  if (!emailSent) {
    try {
      await sendEmail(env.RESEND_API_KEY, env.RESEND_ENABLED === "true", buildLicenseKeyEmail(license));
      emailSent = true;
      if (eventId) {
        await env.DB.prepare("UPDATE purchase_log SET email_sent = 1 WHERE stripe_event_id = ?")
          .bind(eventId)
          .run();
      }
    } catch (err) {
      console.error("email send failed:", err);
    }
  }

  return { status: "fulfilled", license, created, emailSent };
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

export function buildLicenseKeyEmail(license: License): ResendEmail {
  const subject = "PolePole ライセンスキーのお届け";
  const html = `
<!DOCTYPE html>
<html lang="ja">
<body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; color: #1a1a1a; max-width: 560px; margin: 0 auto; padding: 32px 24px;">
  <h1 style="font-size: 20px;">PolePole をご購入いただきありがとうございます</h1>
  <p>ライセンスキーをお届けします。アプリの <strong>Settings → ライセンス</strong> タブで、購入時のメールアドレスとキーを入力してアクティベートしてください。</p>
  <div style="background: #f5f5f7; padding: 16px; border-radius: 8px; margin: 24px 0;">
    <div style="font-size: 12px; color: #666; margin-bottom: 4px;">メールアドレス</div>
    <div style="font-family: ui-monospace, SFMono-Regular, monospace; font-size: 14px;">${license.email}</div>
    <div style="font-size: 12px; color: #666; margin: 12px 0 4px;">ライセンスキー</div>
    <div style="font-family: ui-monospace, SFMono-Regular, monospace; font-size: 14px;">${license.id}</div>
  </div>
  <p style="font-size: 13px; color: #666;">
    ・1 ライセンスにつき 3 台までアクティベートできます<br>
    ・全メジャーバージョン無料アップデート (Lifetime License)<br>
    ・お問い合わせは <a href="mailto:support@polepole.dev">support@polepole.dev</a> まで
  </p>
  <p style="font-size: 13px; color: #666;">— PolePole / <a href="https://polepole.dev">polepole.dev</a></p>
</body>
</html>`;
  const text = `PolePole をご購入いただきありがとうございます。

ライセンスキーをお届けします。アプリの Settings → ライセンスタブで、購入時のメールアドレスとキーを入力してアクティベートしてください。

  メールアドレス: ${license.email}
  ライセンスキー: ${license.id}

・1 ライセンスにつき 3 台までアクティベートできます
・全メジャーバージョン無料アップデート (Lifetime License)
・お問い合わせは support@polepole.dev まで

— PolePole / https://polepole.dev`;
  return {
    from: "PolePole <support@polepole.dev>",
    to: license.email,
    subject,
    html,
    text,
  };
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
