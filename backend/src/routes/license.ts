import { Hono } from "hono";
import { z } from "zod";
import type { Bindings, License } from "../types";
import {
  activateDevice,
  deactivateDevice,
  lookupLicense,
  verifyAndRefresh,
} from "../lib/license-ops";
import { buildLicenseResendEmail } from "../lib/email-templates";
import { sendEmail } from "../lib/resend";
import {
  checkBindingLimit,
  checkLogLimit,
  recordLogEvent,
} from "../lib/rate-limit";

export const licenseRoute = new Hono<{ Bindings: Bindings }>();

const keySchema = z.string().regex(/^polepole-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);
const emailSchema = z.string().email().max(255);
const deviceHashSchema = z.string().min(16).max(128);
const optionalShortString = z.string().max(200).optional();

const activateBody = z.object({
  key: keySchema,
  email: emailSchema,
  device_hash: deviceHashSchema,
  device_name: optionalShortString,
  os_version: optionalShortString,
  app_version: optionalShortString,
});

const deactivateBody = z.object({
  key: keySchema,
  email: emailSchema,
  device_id: z.string().min(8).max(128),
});

const verifyBody = z.object({
  key: keySchema,
  email: emailSchema,
  device_hash: deviceHashSchema,
  os_version: optionalShortString,
  app_version: optionalShortString,
});

const resendBody = z.object({
  email: emailSchema,
});

// 共通: key + email で license を引いて、status 不正なら適切なエラーを返す
type AuthFailStatus = 401 | 403;

async function loadActiveLicense(
  env: Bindings,
  key: string,
  email: string
): Promise<
  | { ok: true; license: License }
  | { ok: false; status: AuthFailStatus; body: Record<string, string> }
> {
  const lookup = await lookupLicense(env, key, email);
  if (lookup.status === "not_found") {
    // セキュリティ的に「key と email どちらが間違っているか」は教えない
    return { ok: false, status: 401, body: { error: "invalid_credentials" } };
  }
  if (lookup.status === "revoked")
    return { ok: false, status: 403, body: { error: "license_revoked" } };
  if (lookup.status === "refunded")
    return { ok: false, status: 403, body: { error: "license_refunded" } };
  return { ok: true, license: lookup.license };
}

function clientIP(c: { req: { header: (k: string) => string | undefined } }): string {
  return c.req.header("cf-connecting-ip") ?? c.req.header("x-forwarded-for") ?? "unknown";
}

// --- POST /v1/license/activate ---
licenseRoute.post("/activate", async (c) => {
  const env = c.env;
  const ip = clientIP(c);
  const binding = await checkBindingLimit(env.RATE_LIMITER_ACTIVATE, ip);
  if (!binding.allowed) return c.json({ error: "rate_limited" }, 429);

  const parsed = activateBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "invalid_body", issues: parsed.error.issues }, 400);
  const body = parsed.data;

  const found = await loadActiveLicense(env, body.key, body.email);
  if (!found.ok) return c.json(found.body, found.status);

  const result = await activateDevice(env, found.license, {
    device_hash: body.device_hash,
    device_name: body.device_name,
    os_version: body.os_version,
    app_version: body.app_version,
  });

  if (result.status === "device_limit") {
    return c.json({ error: "device_limit", existing_devices: result.existing }, 409);
  }

  return c.json({
    status: "ok",
    token: result.token,
    device: {
      id: result.device.id,
      created: result.created,
      activated_at: result.device.activated_at,
    },
  });
});

// --- POST /v1/license/deactivate ---
licenseRoute.post("/deactivate", async (c) => {
  const env = c.env;
  const ip = clientIP(c);
  const binding = await checkBindingLimit(env.RATE_LIMITER_ACTIVATE, ip);
  if (!binding.allowed) return c.json({ error: "rate_limited" }, 429);

  const parsed = deactivateBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "invalid_body", issues: parsed.error.issues }, 400);
  const body = parsed.data;

  const found = await loadActiveLicense(env, body.key, body.email);
  if (!found.ok) return c.json(found.body, found.status);

  const result = await deactivateDevice(env, found.license, body.device_id);
  if (!result.deleted) return c.json({ error: "device_not_found" }, 404);
  return c.json({ status: "ok" });
});

// --- POST /v1/license/verify ---
// 成功時に新しい署名トークンを返す → アプリ側が Keychain 上書きで grace 30 日を自動延長
licenseRoute.post("/verify", async (c) => {
  const env = c.env;
  const ip = clientIP(c);
  const binding = await checkBindingLimit(env.RATE_LIMITER_ACTIVATE, ip);
  if (!binding.allowed) return c.json({ error: "rate_limited" }, 429);

  const parsed = verifyBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "invalid_body", issues: parsed.error.issues }, 400);
  const body = parsed.data;

  const found = await loadActiveLicense(env, body.key, body.email);
  if (!found.ok) return c.json(found.body, found.status);

  const result = await verifyAndRefresh(env, found.license, {
    device_hash: body.device_hash,
    os_version: body.os_version,
    app_version: body.app_version,
  });

  if (result.status === "unknown_device") {
    return c.json({ error: "unknown_device" }, 404);
  }

  return c.json({
    status: "ok",
    token: result.token,
    last_seen_at: result.device.last_seen_at,
  });
});

// --- POST /v1/license/resend ---
// 紛失時の再送。binding (IP) + rate_limit_log (email) の二段。
licenseRoute.post("/resend", async (c) => {
  const env = c.env;
  const ip = clientIP(c);

  const binding = await checkBindingLimit(env.RATE_LIMITER_RESEND, ip);
  if (!binding.allowed) return c.json({ error: "rate_limited" }, 429);

  const parsed = resendBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "invalid_body", issues: parsed.error.issues }, 400);
  const { email } = parsed.data;

  const limitKey = `resend:${email.toLowerCase()}`;
  const logCheck = await checkLogLimit(env, limitKey, [
    { count: 1, perSeconds: 60 },   // 同じ email から 1 分に 1 回
    { count: 5, perSeconds: 86400 }, // 同じ email から 1 日 5 回
  ]);
  if (!logCheck.allowed) return c.json({ error: "rate_limited" }, 429);

  // 同 email に複数 license があれば全部送る (Lifetime なので普通は 1 件)
  const rows = await env.DB.prepare(
    "SELECT * FROM license WHERE lower(email) = lower(?) AND status = 'active'"
  )
    .bind(email)
    .all<License>();
  const licenses = rows.results ?? [];

  // 「該当なし」をユーザーに教えない (email enumeration 対策)
  // ただし rate_limit_log には常に記録する (存在しない email でも消費させる)
  await recordLogEvent(env, limitKey);

  for (const license of licenses) {
    try {
      await sendEmail(env.RESEND_API_KEY, env.RESEND_ENABLED === "true", buildLicenseResendEmail(license));
    } catch (err) {
      console.error("resend failed for license", license.id, err);
    }
  }

  return c.json({ status: "ok" });
});
