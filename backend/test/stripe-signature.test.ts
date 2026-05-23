import { describe, it, expect } from "vitest";
import { verifyStripeSignature } from "../src/lib/stripe";

// Stripe-Signature の expected を自分で計算してテストに渡す。
async function sign(payload: string, secret: string, timestamp: number): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${payload}`))
  );
  let hex = "";
  for (const b of sig) hex += b.toString(16).padStart(2, "0");
  return `t=${timestamp},v1=${hex}`;
}

describe("verifyStripeSignature", () => {
  const SECRET = "whsec_test_secret";
  const PAYLOAD = '{"id":"evt_test","type":"checkout.session.completed"}';
  const NOW = 1_700_000_000;

  it("accepts a valid signature within tolerance", async () => {
    const header = await sign(PAYLOAD, SECRET, NOW - 10);
    await expect(verifyStripeSignature(PAYLOAD, header, SECRET, NOW)).resolves.toBeUndefined();
  });

  it("accepts a valid signature when one of multiple v1 entries matches", async () => {
    const ok = await sign(PAYLOAD, SECRET, NOW);
    const v1 = ok.split("v1=")[1];
    const header = `t=${NOW},v1=deadbeef,v1=${v1}`;
    await expect(verifyStripeSignature(PAYLOAD, header, SECRET, NOW)).resolves.toBeUndefined();
  });

  it("rejects a tampered payload", async () => {
    const header = await sign(PAYLOAD, SECRET, NOW);
    await expect(
      verifyStripeSignature(PAYLOAD + "evil", header, SECRET, NOW)
    ).rejects.toThrow(/verification failed/);
  });

  it("rejects a stale signature outside tolerance", async () => {
    const header = await sign(PAYLOAD, SECRET, NOW - 10 * 60);
    await expect(verifyStripeSignature(PAYLOAD, header, SECRET, NOW)).rejects.toThrow(
      /outside tolerance/
    );
  });

  it("rejects when secret mismatches", async () => {
    const header = await sign(PAYLOAD, SECRET, NOW);
    await expect(verifyStripeSignature(PAYLOAD, header, "wrong", NOW)).rejects.toThrow(
      /verification failed/
    );
  });

  it("rejects a malformed header", async () => {
    await expect(verifyStripeSignature(PAYLOAD, "garbage", SECRET, NOW)).rejects.toThrow(
      /invalid Stripe-Signature/
    );
  });
});
