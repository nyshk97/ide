// EdDSA (Ed25519) によるライセンストークン署名。
// Workers 側は秘密鍵で署名し、アプリ側は公開鍵で検証する。
// トークン形式: `<base64url(payload)>.<base64url(signature)>`
//
// 鍵は PKCS#8 PEM 形式で env (LICENSE_SIGNING_PRIVATE_KEY) から渡される。
// 生成は `pnpm keys:generate` を参照。

import { TOKEN_MAX_OFFLINE_DAYS } from "../types";

export type TokenPayload = {
  key: string;
  email: string;
  device_hash: string;
  license_status: "active" | "revoked" | "refunded";
  issued_at: number;
  max_offline_days: number;
};

function base64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function pemToBinary(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const pkcs8 = pemToBinary(pem);
  return crypto.subtle.importKey(
    "pkcs8",
    pkcs8 as BufferSource,
    { name: "Ed25519" },
    false,
    ["sign"]
  );
}

export async function issueToken(
  payload: Omit<TokenPayload, "issued_at" | "max_offline_days">,
  privateKeyPem: string,
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<string> {
  const full: TokenPayload = {
    ...payload,
    issued_at: nowSeconds,
    max_offline_days: TOKEN_MAX_OFFLINE_DAYS,
  };
  const payloadJson = JSON.stringify(full);
  const payloadBytes = new TextEncoder().encode(payloadJson);
  const key = await importPrivateKey(privateKeyPem);
  const sig = await crypto.subtle.sign({ name: "Ed25519" }, key, payloadBytes as BufferSource);
  return `${base64url(payloadBytes)}.${base64url(new Uint8Array(sig))}`;
}
