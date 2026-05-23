// activate / deactivate / verify の core ロジック。
// Hono ルートから呼ばれる側で、D1 操作とトークン発行を担う。

import type { Bindings, Device, License } from "../types";
import { DEVICE_LIMIT } from "../types";
import { issueToken } from "./signing";

export type DeviceInfo = {
  device_hash: string;
  device_name?: string | null;
  os_version?: string | null;
  app_version?: string | null;
};

export type LicenseLookupResult =
  | { status: "ok"; license: License }
  | { status: "not_found" }
  | { status: "revoked" }
  | { status: "refunded" };

// key + email で license を引く。
// email は case-insensitive で比較する (ユーザーが大文字小文字を入力ミスする可能性高い)。
export async function lookupLicense(
  env: Bindings,
  key: string,
  email: string
): Promise<LicenseLookupResult> {
  const license = await env.DB.prepare(
    "SELECT * FROM license WHERE id = ? AND lower(email) = lower(?)"
  )
    .bind(key, email)
    .first<License>();
  if (!license) return { status: "not_found" };
  if (license.status === "revoked") return { status: "revoked" };
  if (license.status === "refunded") return { status: "refunded" };
  return { status: "ok", license };
}

export type ActivateResult =
  | { status: "ok"; device: Device; created: boolean; token: string }
  | { status: "device_limit"; existing: PublicDevice[] };

export type PublicDevice = {
  id: string;
  device_name: string | null;
  os_version: string | null;
  app_version: string | null;
  activated_at: number;
  last_seen_at: number;
};

function toPublicDevice(d: Device): PublicDevice {
  return {
    id: d.id,
    device_name: d.device_name,
    os_version: d.os_version,
    app_version: d.app_version,
    activated_at: d.activated_at,
    last_seen_at: d.last_seen_at,
  };
}

// activate:
//   既存 device (license_id, device_hash) があれば UPDATE して継続使用 (上限カウントに含めない)。
//   なければ COUNT < DEVICE_LIMIT のときだけ INSERT。
//   両方とも該当しなければ device_limit エラーで existing デバイス一覧を返す。
//
// D1 batch でアトミック実行する (count と insert を別クエリで分けると並列 activate で 4 台目が
// すり抜ける可能性がある)。
export async function activateDevice(
  env: Bindings,
  license: License,
  device: DeviceInfo,
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<ActivateResult> {
  const deviceId = crypto.randomUUID();

  const updateStmt = env.DB.prepare(
    `UPDATE device SET
       device_name = ?, os_version = ?, app_version = ?, last_seen_at = ?
     WHERE license_id = ? AND device_hash = ?`
  ).bind(
    device.device_name ?? null,
    device.os_version ?? null,
    device.app_version ?? null,
    nowSeconds,
    license.id,
    device.device_hash
  );

  const insertStmt = env.DB.prepare(
    `INSERT INTO device
       (id, license_id, device_hash, device_name, os_version, app_version, activated_at, last_seen_at)
     SELECT ?, ?, ?, ?, ?, ?, ?, ?
     WHERE NOT EXISTS (SELECT 1 FROM device WHERE license_id = ? AND device_hash = ?)
       AND (SELECT COUNT(*) FROM device WHERE license_id = ?) < ?`
  ).bind(
    deviceId,
    license.id,
    device.device_hash,
    device.device_name ?? null,
    device.os_version ?? null,
    device.app_version ?? null,
    nowSeconds,
    nowSeconds,
    license.id,
    device.device_hash,
    license.id,
    DEVICE_LIMIT
  );

  const selectStmt = env.DB.prepare(
    "SELECT * FROM device WHERE license_id = ? ORDER BY activated_at ASC"
  ).bind(license.id);

  const [, , devicesResult] = await env.DB.batch([updateStmt, insertStmt, selectStmt]);
  const devices = (devicesResult.results ?? []) as Device[];
  const own = devices.find((d) => d.device_hash === device.device_hash);

  if (!own) {
    // INSERT も UPDATE も入らなかった = 新規かつ上限超過
    return { status: "device_limit", existing: devices.map(toPublicDevice) };
  }

  const token = await issueSignedToken(env, license, own, nowSeconds);
  const created = own.id === deviceId;
  return { status: "ok", device: own, created, token };
}

export async function deactivateDevice(
  env: Bindings,
  license: License,
  deviceId: string
): Promise<{ deleted: boolean }> {
  // license_id を必ず WHERE に含めて、他のライセンスのデバイスを消せないようにする。
  const result = await env.DB.prepare(
    "DELETE FROM device WHERE id = ? AND license_id = ?"
  )
    .bind(deviceId, license.id)
    .run();
  return { deleted: (result.meta?.changes ?? 0) > 0 };
}

export type VerifyResult =
  | { status: "ok"; token: string; device: Device }
  | { status: "unknown_device" };

// verify: device の last_seen_at / os_version / app_version を更新し、
// 新しい署名トークン (issued_at = now) を返す。アプリ側はこれを Keychain に上書きして
// 30 日 grace を自動延長する。
export async function verifyAndRefresh(
  env: Bindings,
  license: License,
  device: DeviceInfo,
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<VerifyResult> {
  const updated = await env.DB.prepare(
    `UPDATE device SET last_seen_at = ?, os_version = ?, app_version = ?
     WHERE license_id = ? AND device_hash = ?`
  )
    .bind(
      nowSeconds,
      device.os_version ?? null,
      device.app_version ?? null,
      license.id,
      device.device_hash
    )
    .run();

  if ((updated.meta?.changes ?? 0) === 0) {
    return { status: "unknown_device" };
  }

  const d = await env.DB.prepare(
    "SELECT * FROM device WHERE license_id = ? AND device_hash = ?"
  )
    .bind(license.id, device.device_hash)
    .first<Device>();
  if (!d) return { status: "unknown_device" };

  const token = await issueSignedToken(env, license, d, nowSeconds);
  return { status: "ok", token, device: d };
}

async function issueSignedToken(
  env: Bindings,
  license: License,
  device: Device,
  nowSeconds: number
): Promise<string> {
  if (!env.LICENSE_SIGNING_PRIVATE_KEY) {
    throw new Error("LICENSE_SIGNING_PRIVATE_KEY is not set");
  }
  return await issueToken(
    {
      key: license.id,
      email: license.email,
      device_hash: device.device_hash,
      license_status: license.status,
    },
    env.LICENSE_SIGNING_PRIVATE_KEY,
    nowSeconds
  );
}
