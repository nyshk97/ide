// Stripe API への薄い fetch ラッパー。
// stripe-node SDK (200KB+) を入れずに済むよう、必要な endpoint だけ書く。
// 認証は Bearer。form-encoded body は使わず GET だけで足りる範囲に絞る。

export type StripeCheckoutSession = {
  id: string;
  object: "checkout.session";
  payment_status: "paid" | "unpaid" | "no_payment_required";
  amount_total: number | null;
  currency: string | null;
  customer_details: {
    email: string | null;
  } | null;
  payment_intent: string | null;
  payment_link: string | null;
  metadata: Record<string, string> | null;
  line_items?: {
    data: Array<{
      price: {
        id: string;
      } | null;
    }>;
  };
};

export class StripeApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "StripeApiError";
  }
}

export async function retrieveCheckoutSession(
  apiKey: string,
  sessionId: string
): Promise<StripeCheckoutSession> {
  // line_items は expand しないと付いてこない。Price ID 検証で必要。
  const url = `https://api.stripe.com/v1/checkout/sessions/${encodeURIComponent(sessionId)}?expand[]=line_items`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new StripeApiError(res.status, `Stripe retrieve session failed: ${res.status} ${text}`);
  }
  return (await res.json()) as StripeCheckoutSession;
}

// --- Webhook 署名検証 ---
// Stripe-Signature ヘッダ: `t=<timestamp>,v1=<sig>,v1=<sig>...`
// signed_payload = `<timestamp>.<body>`
// expected = HMAC-SHA256(secret, signed_payload)

const SIGNATURE_TOLERANCE_SECONDS = 5 * 60;

function parseSignatureHeader(header: string): { timestamp: number; v1: string[] } {
  const parts = header.split(",").map((s) => s.trim());
  let timestamp: number | null = null;
  const v1: string[] = [];
  for (const p of parts) {
    const eq = p.indexOf("=");
    if (eq < 0) continue;
    const k = p.slice(0, eq);
    const v = p.slice(eq + 1);
    if (k === "t") timestamp = Number(v);
    else if (k === "v1") v1.push(v);
  }
  if (timestamp === null || Number.isNaN(timestamp) || v1.length === 0) {
    throw new Error("invalid Stripe-Signature header");
  }
  return { timestamp, v1 };
}

function hexEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function bytesToHex(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

export async function verifyStripeSignature(
  rawBody: string,
  signatureHeader: string,
  secret: string,
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<void> {
  const { timestamp, v1 } = parseSignatureHeader(signatureHeader);
  if (Math.abs(nowSeconds - timestamp) > SIGNATURE_TOLERANCE_SECONDS) {
    throw new Error("Stripe signature timestamp is outside tolerance");
  }
  const signedPayload = `${timestamp}.${rawBody}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret) as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigBytes = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      key,
      new TextEncoder().encode(signedPayload) as BufferSource
    )
  );
  const expected = bytesToHex(sigBytes);
  if (!v1.some((s) => hexEqual(s, expected))) {
    throw new Error("Stripe signature verification failed");
  }
}
