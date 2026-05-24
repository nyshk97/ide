import { describe, it, expect } from "vitest";
import {
  buildLicenseKeyEmail,
  buildLicenseResendEmail,
  buildUniversalTokenEmail,
} from "../src/lib/email-templates";
import type { License } from "../src/types";

const sampleLicense: License = {
  id: "polepole-ABCD-EFGH-JKMN-PQRS",
  email: "buyer@example.com",
  stripe_session_id: "cs_test_123",
  stripe_payment_intent_id: "pi_test_123",
  amount: 9900,
  currency: "jpy",
  status: "active",
  email_sent_at: null,
  created_at: 1700000000,
  updated_at: 1700000000,
};

describe("buildLicenseKeyEmail (購入直後)", () => {
  const email = buildLicenseKeyEmail(sampleLicense);

  it("from は noreply@polepole.dev (送信専用)", () => {
    expect(email.from).toBe("PolePole <noreply@polepole.dev>");
  });
  it("to は license.email", () => {
    expect(email.to).toBe("buyer@example.com");
  });
  it("subject に「ご購入ありがとうございます」と「ライセンスキー」が含まれる", () => {
    expect(email.subject).toMatch(/ご購入ありがとうございます/);
    expect(email.subject).toMatch(/ライセンスキー/);
  });
  it("HTML に key と email が表示される", () => {
    expect(email.html).toContain(sampleLicense.id);
    expect(email.html).toContain(sampleLicense.email);
  });
  it("text に key と email が表示される", () => {
    expect(email.text).toContain(sampleLicense.id);
    expect(email.text).toContain(sampleLicense.email);
  });
  it("HTML/text の両方に Lifetime License とお問い合わせフォーム URL が含まれる", () => {
    expect(email.html).toMatch(/Lifetime License/);
    expect(email.html).toContain("https://polepole.dev/contact");
    expect(email.text).toMatch(/Lifetime License/);
    expect(email.text).toContain("https://polepole.dev/contact");
  });
});

describe("buildLicenseResendEmail (紛失再送)", () => {
  const email = buildLicenseResendEmail(sampleLicense);

  it("subject が「再送」を含み、購入直後のものとは別タイトル", () => {
    expect(email.subject).toMatch(/再送/);
    expect(email.subject).not.toMatch(/ご購入ありがとうございます/);
  });
  it("身に覚えがない場合の注意文が含まれる (defense-in-depth)", () => {
    expect(email.html).toMatch(/お心当たり|破棄/);
    expect(email.text).toMatch(/お心当たり|破棄/);
  });
  it("HTML/text に key と email が表示される", () => {
    expect(email.html).toContain(sampleLicense.id);
    expect(email.html).toContain(sampleLicense.email);
    expect(email.text).toContain(sampleLicense.id);
    expect(email.text).toContain(sampleLicense.email);
  });
});

describe("buildUniversalTokenEmail (サ終時 universal token)", () => {
  const email = buildUniversalTokenEmail({
    email: "buyer@example.com",
    licenseKey: "polepole-ABCD-EFGH-JKMN-PQRS",
    universalToken: "eyJhbGciOiJFZERTQSJ9.dGVzdA.signed_token_blob",
    shutdownDate: "2030-12-31",
  });

  it("件名にサービス終了とトークン案内が含まれる", () => {
    expect(email.subject).toMatch(/サービス終了/);
    expect(email.subject).toMatch(/トークン/);
  });
  it("本文にライセンスキーと universal token と終了日が埋まる", () => {
    expect(email.html).toContain("polepole-ABCD-EFGH-JKMN-PQRS");
    expect(email.html).toContain("eyJhbGciOiJFZERTQSJ9.dGVzdA.signed_token_blob");
    expect(email.html).toContain("2030-12-31");
    expect(email.text).toContain("polepole-ABCD-EFGH-JKMN-PQRS");
    expect(email.text).toContain("eyJhbGciOiJFZERTQSJ9.dGVzdA.signed_token_blob");
    expect(email.text).toContain("2030-12-31");
  });
  it("取り込み手順が両方に含まれる", () => {
    expect(email.html).toMatch(/Settings → ライセンス/);
    expect(email.text).toMatch(/Settings → ライセンス/);
  });
});
