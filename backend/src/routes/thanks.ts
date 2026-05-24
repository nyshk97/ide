import { Hono } from "hono";
import { html } from "hono/html";
import type { Bindings } from "../types";
import { fulfillCheckout } from "../lib/fulfillment";

export const thanksRoute = new Hono<{ Bindings: Bindings }>();

// Stripe Payment Link の success_url から GET で叩かれる。
// session_id を Stripe API で検証 → fulfillCheckout (webhook と同じ関数) → license を画面表示。
// webhook より /thanks の方が先に届くケースが普通なので、ここでほぼ毎回 license が新規作成される想定。

// i18n scaffold: `?lang=en` を受ける slot だけ用意。中身は当面 JP 固定。
// 本翻訳投入時に EN HTML を生やす + Stripe 側 success_url に `?lang=en` を埋める
// (EN 用 Payment Link を別途作って success_url に組み込む) ことで EN レンダリングに切り替わる。
type Lang = "ja" | "en";
function parseLang(c: { req: { query: (k: string) => string | undefined } }): Lang {
  return c.req.query("lang") === "en" ? "en" : "ja";
}

thanksRoute.get("/", async (c) => {
  const lang = parseLang(c);
  const sessionId = c.req.query("session_id");
  if (!sessionId) {
    return c.html(errorPage("session_id がありません。購入完了ページから来てください。", lang), 400);
  }

  try {
    const result = await fulfillCheckout(c.env, sessionId, "thanks_page");
    if (result.status === "rejected") {
      return c.html(
        errorPage(
          `この決済はライセンス発行条件を満たしていませんでした (reason: ${result.reason})。
お心当たりが無い場合は https://polepole.dev/contact よりご連絡ください。`,
          lang
        ),
        400
      );
    }
    return c.html(successPage(result.license.id, result.license.email, result.emailSent, lang));
  } catch (err) {
    console.error("/thanks fulfillment error:", err);
    return c.html(
      errorPage(
        `内部エラーで処理に失敗しました。お手数ですが、購入時のメールアドレスを添えて
https://polepole.dev/contact よりご連絡ください。`,
        lang
      ),
      500
    );
  }
});

function successPage(key: string, email: string, emailSent: boolean, _lang: Lang) {
  // TODO(i18n): _lang === "en" になったら EN HTML を生やす。
  // それまでは JP 固定でレンダリング。
  return html`<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>PolePole — ご購入ありがとうございます</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; line-height: 1.6; color: #1a1a1a; max-width: 560px; margin: 0 auto; padding: 48px 24px; }
    h1 { font-size: 24px; margin-top: 0; }
    .card { background: #f5f5f7; padding: 16px; border-radius: 8px; margin: 24px 0; }
    .label { font-size: 12px; color: #666; margin-bottom: 4px; }
    .value { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 14px; word-break: break-all; }
    .value + .label { margin-top: 12px; }
    .small { font-size: 13px; color: #666; }
    a { color: #0066cc; }
  </style>
</head>
<body>
  <h1>PolePole をご購入いただきありがとうございます</h1>
  <p>下記のライセンスキーで PolePole をアクティベートしてください。アプリの <strong>Settings → ライセンス</strong> タブで、メールアドレスとキーを入力します。</p>
  <div class="card">
    <div class="label">メールアドレス</div>
    <div class="value">${email}</div>
    <div class="label">ライセンスキー</div>
    <div class="value">${key}</div>
  </div>
  <p class="small">
    ${emailSent
      ? "同じ内容をメールでもお送りしました。届かない場合は迷惑メールフォルダもご確認ください。"
      : "メール送信に失敗しているか、配信が遅れています。このページのキーを保管しておくか、https://polepole.dev/contact よりお問い合わせください。"}
  </p>
  <p class="small">
    ・1 ライセンスにつき 3 台までアクティベートできます<br>
    ・全メジャーバージョン無料アップデート (Lifetime License)<br>
    ・お問い合わせ: <a href="https://polepole.dev/contact">お問い合わせフォーム</a>
  </p>
</body>
</html>`;
}

function errorPage(message: string, _lang: Lang = "ja") {
  // TODO(i18n): _lang === "en" になったら EN HTML を生やす。
  return html`<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>PolePole — 処理エラー</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", sans-serif; line-height: 1.6; color: #1a1a1a; max-width: 560px; margin: 0 auto; padding: 48px 24px; }
    h1 { font-size: 22px; }
    a { color: #0066cc; }
  </style>
</head>
<body>
  <h1>処理に失敗しました</h1>
  <p>${message}</p>
  <p><a href="https://polepole.dev">polepole.dev に戻る</a></p>
</body>
</html>`;
}
