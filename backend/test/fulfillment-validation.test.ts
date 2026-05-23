import { describe, it, expect } from "vitest";
import { validateSession, type ValidationEnv } from "../src/lib/fulfillment";
import type { StripeCheckoutSession } from "../src/lib/stripe";

const ENV: ValidationEnv = {
  EXPECTED_AMOUNT: "11800",
  EXPECTED_CURRENCY: "jpy",
  EXPECTED_PRICE_ID: "price_test",
  EXPECTED_PAYMENT_LINK_ID: "plink_test",
};

function makeSession(overrides: Partial<StripeCheckoutSession> = {}): StripeCheckoutSession {
  return {
    id: "cs_test_123",
    object: "checkout.session",
    payment_status: "paid",
    amount_total: 11800,
    currency: "jpy",
    customer_details: { email: "buyer@example.com" },
    payment_intent: "pi_test_123",
    payment_link: "plink_test",
    metadata: null,
    line_items: {
      data: [{ price: { id: "price_test" } }],
    },
    ...overrides,
  };
}

describe("validateSession", () => {
  it("accepts a fully-valid paid session", () => {
    const res = validateSession(makeSession(), ENV);
    expect(res.ok).toBe(true);
    if (res.ok) {
      expect(res.data).toEqual({
        email: "buyer@example.com",
        amount: 11800,
        currency: "jpy",
        paymentIntentId: "pi_test_123",
      });
    }
  });

  it("rejects unpaid sessions", () => {
    const res = validateSession(makeSession({ payment_status: "unpaid" }), ENV);
    expect(res).toEqual({ ok: false, reason: "not_paid" });
  });

  it("rejects no_payment_required (zero amount) sessions", () => {
    const res = validateSession(
      makeSession({ payment_status: "no_payment_required", amount_total: 0 }),
      ENV
    );
    expect(res).toEqual({ ok: false, reason: "not_paid" });
  });

  it("rejects amount mismatch (price tampering)", () => {
    const res = validateSession(makeSession({ amount_total: 100 }), ENV);
    expect(res).toEqual({ ok: false, reason: "amount_mismatch" });
  });

  it("rejects currency mismatch", () => {
    const res = validateSession(makeSession({ currency: "usd" }), ENV);
    expect(res).toEqual({ ok: false, reason: "currency_mismatch" });
  });

  it("accepts currency in different case", () => {
    const res = validateSession(makeSession({ currency: "JPY" }), ENV);
    expect(res.ok).toBe(true);
  });

  it("rejects Price ID mismatch", () => {
    const res = validateSession(
      makeSession({ line_items: { data: [{ price: { id: "price_evil" } }] } }),
      ENV
    );
    expect(res).toEqual({ ok: false, reason: "price_mismatch" });
  });

  it("rejects Payment Link mismatch", () => {
    const res = validateSession(makeSession({ payment_link: "plink_evil" }), ENV);
    expect(res).toEqual({ ok: false, reason: "payment_link_mismatch" });
  });

  it("rejects when payment_link is null (direct API checkout instead of Payment Link)", () => {
    const res = validateSession(makeSession({ payment_link: null }), ENV);
    expect(res).toEqual({ ok: false, reason: "payment_link_mismatch" });
  });

  it("rejects when customer email is missing", () => {
    const res = validateSession(
      makeSession({ customer_details: { email: null } }),
      ENV
    );
    expect(res).toEqual({ ok: false, reason: "no_email" });
  });

  it("rejects when customer_details is null", () => {
    const res = validateSession(makeSession({ customer_details: null }), ENV);
    expect(res).toEqual({ ok: false, reason: "no_email" });
  });

  it("rejects when line_items is missing", () => {
    const res = validateSession(makeSession({ line_items: undefined }), ENV);
    expect(res).toEqual({ ok: false, reason: "price_mismatch" });
  });
});
