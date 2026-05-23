import { Hono } from "hono";
import type { Bindings } from "../types";
import { verifyStripeSignature } from "../lib/stripe";
import { fulfillCheckout, markRefunded } from "../lib/fulfillment";

export const webhookRoute = new Hono<{ Bindings: Bindings }>();

type StripeEvent = {
  id: string;
  type: string;
  data: { object: Record<string, unknown> };
};

webhookRoute.post("/", async (c) => {
  const env = c.env;
  if (!env.STRIPE_WEBHOOK_SECRET || env.STRIPE_WEBHOOK_SECRET.startsWith("whsec_placeholder")) {
    return c.json({ error: "stripe_webhook_secret_not_configured" }, 503);
  }

  const sig = c.req.header("stripe-signature");
  if (!sig) return c.json({ error: "missing_signature" }, 400);

  const rawBody = await c.req.text();
  try {
    await verifyStripeSignature(rawBody, sig, env.STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.warn("stripe signature verification failed:", err);
    return c.json({ error: "invalid_signature" }, 400);
  }

  let event: StripeEvent;
  try {
    event = JSON.parse(rawBody) as StripeEvent;
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }

  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object as { id?: string };
      if (!session.id) return c.json({ error: "no_session_id" }, 400);
      const result = await fulfillCheckout(env, session.id, "webhook", event.id);
      if (result.status === "rejected") {
        console.warn(`fulfillment rejected: ${result.reason} (session=${session.id})`);
        // Stripe には 200 を返す (リトライさせない) が、内部的には監査の必要がある状態
        return c.json({ status: "rejected", reason: result.reason });
      }
      return c.json({
        status: "fulfilled",
        created: result.created,
        email_sent: result.emailSent,
      });
    }

    case "refund.created":
    case "charge.refunded": {
      const obj = event.data.object as { payment_intent?: string };
      if (!obj.payment_intent) return c.json({ error: "no_payment_intent" }, 400);
      const result = await markRefunded(env, obj.payment_intent);
      return c.json({ status: "refunded", updated: result.updated });
    }

    default:
      // 未対応 event は 200 で受け流す (Stripe が無駄にリトライしないように)
      return c.json({ status: "ignored", type: event.type });
  }
});
