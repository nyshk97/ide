// Rate limit の二段構え:
// 1. Cloudflare の RateLimit binding (IP ベース、wrangler.toml で設定)
// 2. D1 の rate_limit_log (email ベース等、IP では取れない粒度)
//
// 第一線は binding (高速、スキーマ不要)。binding に弾かれたら 429。
// binding を通った後、email 等の細粒度制限を rate_limit_log で確認。

import type { Bindings, RateLimit } from "../types";

export async function checkBindingLimit(
  limiter: RateLimit,
  key: string
): Promise<{ allowed: boolean }> {
  try {
    const result = await limiter.limit({ key });
    return { allowed: result.success };
  } catch (err) {
    // binding 自体が壊れている場合 (ローカル開発で remote resource に届かない等) は通す。
    // 第二線の D1 ベースで救う。
    console.warn("rate limit binding error, passing through:", err);
    return { allowed: true };
  }
}

export type LimitWindow = { count: number; perSeconds: number };

// rate_limit_log を使った email/key ベースのレート制限。
// 与えられたキー (e.g. "resend:foo@bar.com") の windows[i] それぞれを満たすか確認。
export async function checkLogLimit(
  env: Bindings,
  key: string,
  windows: LimitWindow[],
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<{ allowed: boolean; violatedWindow?: LimitWindow }> {
  for (const w of windows) {
    const since = nowSeconds - w.perSeconds;
    const row = await env.DB.prepare(
      "SELECT COUNT(*) as n FROM rate_limit_log WHERE key = ? AND occurred_at >= ?"
    )
      .bind(key, since)
      .first<{ n: number }>();
    if ((row?.n ?? 0) >= w.count) {
      return { allowed: false, violatedWindow: w };
    }
  }
  return { allowed: true };
}

// 制限を消費 (= イベント発生記録)。失敗しても呼び出し側は続行できる。
export async function recordLogEvent(
  env: Bindings,
  key: string,
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<void> {
  await env.DB.prepare("INSERT INTO rate_limit_log (key, occurred_at) VALUES (?, ?)")
    .bind(key, nowSeconds)
    .run();
}
