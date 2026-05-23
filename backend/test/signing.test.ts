import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { issueToken } from "../src/lib/signing";

// gen-license-keys.sh で生成した鍵を直接読み込んで、
// 「Workers 側で署名 -> アプリ側で検証」のラウンドトリップが通るか確認する。
// ローカル鍵がない環境 (CI 等) では skip。
const PRIVATE_KEY_PATH = `${process.env.HOME}/Library/CloudStorage/Dropbox/dotfiles/secrets/polepole/license-signing-private.pem`;
const PUBLIC_KEY_PATH = resolve(__dirname, "../../Resources/License/license-pubkey.pem");
const hasKeys = existsSync(PRIVATE_KEY_PATH) && existsSync(PUBLIC_KEY_PATH);

function base64urlDecode(s: string): Uint8Array {
  let t = s.replaceAll("-", "+").replaceAll("_", "/");
  while (t.length % 4) t += "=";
  const bin = atob(t);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function importPublicKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return crypto.subtle.importKey("spki", bytes as BufferSource, { name: "Ed25519" }, false, ["verify"]);
}

describe.skipIf(!hasKeys)("signing roundtrip with real keys", () => {
  const privateKeyPem = hasKeys ? readFileSync(PRIVATE_KEY_PATH, "utf-8") : "";
  const publicKeyPem = hasKeys ? readFileSync(PUBLIC_KEY_PATH, "utf-8") : "";

  it("issues a token that the public key can verify", async () => {
    const token = await issueToken(
      {
        key: "polepole-AAAA-BBBB-CCCC-DDDD",
        email: "test@example.com",
        device_hash: "deadbeef",
        license_status: "active",
      },
      privateKeyPem,
      1700000000
    );
    const [payloadB64, sigB64] = token.split(".");
    expect(payloadB64).toBeTruthy();
    expect(sigB64).toBeTruthy();

    const payloadBytes = base64urlDecode(payloadB64);
    const sigBytes = base64urlDecode(sigB64);
    const pubKey = await importPublicKey(publicKeyPem);
    const ok = await crypto.subtle.verify(
      { name: "Ed25519" },
      pubKey,
      sigBytes as BufferSource,
      payloadBytes as BufferSource
    );
    expect(ok).toBe(true);

    const payload = JSON.parse(new TextDecoder().decode(payloadBytes));
    expect(payload).toMatchObject({
      key: "polepole-AAAA-BBBB-CCCC-DDDD",
      email: "test@example.com",
      device_hash: "deadbeef",
      license_status: "active",
      issued_at: 1700000000,
      max_offline_days: 30,
    });
  });

  it("accepts \\n-escaped PEM as it appears in .dev.vars", async () => {
    const escapedPem = privateKeyPem.replace(/\n/g, "\\n");
    const token = await issueToken(
      {
        key: "polepole-EEEE-FFFF-GGGG-HHHH",
        email: "x@y.z",
        device_hash: "abc",
        license_status: "active",
      },
      escapedPem
    );
    const [payloadB64, sigB64] = token.split(".");
    const pubKey = await importPublicKey(publicKeyPem);
    const ok = await crypto.subtle.verify(
      { name: "Ed25519" },
      pubKey,
      base64urlDecode(sigB64) as BufferSource,
      base64urlDecode(payloadB64) as BufferSource
    );
    expect(ok).toBe(true);
  });
});
