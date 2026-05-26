import { Hono } from "hono";
import type { Bindings } from "../types";

// /appcast.xml だけを担当 (root にマウント)
export const appcastRoute = new Hono<{ Bindings: Bindings }>();
// /download/:version/:asset を担当 (/download にマウント)
export const downloadsRoute = new Hono<{ Bindings: Bindings }>();

const RELEASES_REPO = "nyshk97/polepole-releases";
const GITHUB_BASE = `https://github.com/${RELEASES_REPO}/releases`;
const PROXY_BASE = "https://polepole.dev/download";

// Sparkle: "polepole/1.4.2 Sparkle/2.9.1"
// Homebrew: "Homebrew/4.x.y (Macintosh; ...)"
// curl: "curl/8.x"
// Browser: "Mozilla/5.0 (Macintosh; ...) ..."
export type Classification = "sparkle" | "homebrew" | "browser" | "curl" | "other";

export function classifyUA(ua: string | undefined | null): Classification {
  if (!ua) return "other";
  if (/\bSparkle\//.test(ua)) return "sparkle";
  if (/\bHomebrew\//i.test(ua)) return "homebrew";
  if (/^curl\//i.test(ua)) return "curl";
  if (/^Mozilla\//.test(ua)) return "browser";
  return "other";
}

async function recordEvent(
  env: Bindings,
  params: {
    resource: "appcast" | "download";
    version: string | null;
    asset: string;
    userAgent: string | null;
    country: string | null;
  }
): Promise<void> {
  try {
    await env.DB.prepare(
      `INSERT INTO download_event
        (occurred_at, classification, resource, version, asset, user_agent, country)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    )
      .bind(
        Date.now(),
        classifyUA(params.userAgent),
        params.resource,
        params.version,
        params.asset,
        params.userAgent ?? null,
        params.country ?? null
      )
      .run();
  } catch (err) {
    // ログ書き込み失敗で配信を止めない。redirect / フィード返却は継続する。
    console.error("download_event insert failed:", err);
  }
}

// GET /appcast.xml
// GitHub Releases の最新 appcast.xml を取得し、<enclosure url> を
// polepole.dev/download/... に書き換えてから返す。Sparkle が更新チェックする時の入り口。
appcastRoute.get("/appcast.xml", async (c) => {
  const ua = c.req.header("user-agent") ?? null;
  const country = c.req.header("cf-ipcountry") ?? null;

  // ログ書きは waitUntil で並列実行 (応答を遅らせない)
  c.executionCtx.waitUntil(
    recordEvent(c.env, {
      resource: "appcast",
      version: null,
      asset: "appcast.xml",
      userAgent: ua,
      country,
    })
  );

  const upstream = await fetch(`${GITHUB_BASE}/latest/download/appcast.xml`, {
    cf: { cacheTtl: 60, cacheEverything: true },
    headers: { "user-agent": "polepole-backend/appcast-proxy" },
  });

  if (!upstream.ok) {
    return c.text("upstream error", { status: 502 });
  }

  const xml = await upstream.text();
  // <enclosure url="https://github.com/nyshk97/polepole-releases/releases/download/vX.Y.Z/asset"
  // を proxy 経由 URL に置換。Sparkle がこちらを叩けば binary DL も Workers を通る。
  const rewritten = xml.replace(
    new RegExp(`${GITHUB_BASE}/download/`, "g"),
    `${PROXY_BASE}/`
  );

  return new Response(rewritten, {
    status: 200,
    headers: {
      "content-type": "application/rss+xml; charset=utf-8",
      // Sparkle は 24h 周期で叩く。5 分キャッシュで GitHub への負荷を抑えつつ
      // リリース直後の伝搬遅延も実用範囲。
      "cache-control": "public, max-age=300",
    },
  });
});

// GET /download/:version/:asset
// 例: /download/v1.4.2/polepole.dmg, /download/latest/polepole.dmg
// UA でログ → 302 redirect で GitHub Releases に飛ばす。
downloadsRoute.get("/:version/:asset", async (c) => {
  const version = c.req.param("version");
  const asset = c.req.param("asset");
  const ua = c.req.header("user-agent") ?? null;
  const country = c.req.header("cf-ipcountry") ?? null;

  // version は "latest" または "vX.Y.Z" だけ許可。任意文字列を通すと open redirect になる。
  if (!/^(latest|v\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?)$/.test(version)) {
    return c.text("invalid version", { status: 400 });
  }
  // asset 名は英数 + ドット + ハイフン + アンダースコアのみ。Path traversal を絶対避ける。
  if (!/^[A-Za-z0-9._-]+$/.test(asset)) {
    return c.text("invalid asset", { status: 400 });
  }

  c.executionCtx.waitUntil(
    recordEvent(c.env, {
      resource: "download",
      version,
      asset,
      userAgent: ua,
      country,
    })
  );

  const target = `${GITHUB_BASE}/${version === "latest" ? "latest/download" : `download/${version}`}/${asset}`;
  return c.redirect(target, 302);
});
