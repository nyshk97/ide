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
  <link rel="stylesheet" href="/styles.css">
  <style>
    .thanks-wrap { max-width: 640px; margin: 0 auto; padding: 64px 24px 96px; }
    .thanks-hero { text-align: center; margin-bottom: 48px; }
    .thanks-hero img { width: 96px; height: 96px; display: block; margin: 0 auto 20px; }
    .thanks-hero h1 { font-size: 32px; font-weight: 700; letter-spacing: -0.02em; margin: 0 0 8px; line-height: 1.2; }
    .thanks-hero p { color: var(--text-muted); margin: 0; font-size: 16px; }

    .license-card { background: var(--bg-elevated); border: 1px solid var(--border); border-radius: var(--radius); padding: 24px; margin-bottom: 24px; }
    .license-row { padding: 14px 0; border-bottom: 1px solid var(--border); }
    .license-row:first-child { padding-top: 0; }
    .license-row:last-child { padding-bottom: 0; border-bottom: none; }
    .license-label { font-size: 12px; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 6px; font-weight: 600; }
    .license-value-row { display: flex; align-items: center; gap: 12px; }
    .license-value { flex: 1; font-family: ui-monospace, "SF Mono", SFMono-Regular, monospace; font-size: 15px; word-break: break-all; color: var(--text); }
    .copy-btn { flex-shrink: 0; background: transparent; border: 1px solid var(--border); color: var(--text); padding: 6px 12px; font-size: 13px; border-radius: var(--radius-small); cursor: pointer; font-family: inherit; transition: background-color 120ms, border-color 120ms, color 120ms; }
    .copy-btn:hover { background: var(--bg); border-color: var(--accent); color: var(--accent); }
    .copy-btn.copied { background: var(--accent); border-color: var(--accent); color: #fff; }

    .email-notice { font-size: 14px; color: var(--text-muted); background: var(--bg-elevated); border-left: 3px solid var(--accent); padding: 12px 16px; border-radius: var(--radius-small); margin-bottom: 32px; }
    .email-notice.warn { border-left-color: #d97706; }

    .steps { background: var(--bg-elevated); border: 1px solid var(--border); border-radius: var(--radius); padding: 24px 28px; margin-bottom: 32px; }
    .steps h2 { font-size: 17px; margin: 0 0 16px; letter-spacing: -0.01em; }
    .steps ol { list-style: none; counter-reset: step; padding: 0; margin: 0; }
    .steps li { counter-increment: step; padding: 8px 0 8px 36px; position: relative; font-size: 15px; line-height: 1.55; }
    .steps li::before { content: counter(step); position: absolute; left: 0; top: 8px; width: 24px; height: 24px; background: var(--accent); color: #fff; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 600; }
    .steps kbd { display: inline-block; padding: 1px 7px; font-size: 12px; font-family: ui-monospace, "SF Mono", SFMono-Regular, monospace; background: var(--bg); border: 1px solid var(--border); border-radius: 4px; box-shadow: 0 1px 0 rgba(0,0,0,0.05); color: var(--text); }

    .notes { font-size: 13px; color: var(--text-muted); line-height: 1.7; }
    .notes ul { list-style: none; padding: 0; margin: 0; }
    .notes li { padding: 2px 0 2px 18px; position: relative; }
    .notes li::before { content: "•"; position: absolute; left: 4px; color: var(--accent); }

    .thanks-footer { margin-top: 48px; text-align: center; }
  </style>
</head>
<body>
  <div class="thanks-wrap">
    <div class="thanks-hero">
      <img src="/app-icon.png" alt="PolePole" width="96" height="96">
      <h1>ご購入ありがとうございます</h1>
      <p>下記の情報で PolePole をアクティベートしてください。</p>
    </div>

    <div class="license-card">
      <div class="license-row">
        <div class="license-label">メールアドレス</div>
        <div class="license-value-row">
          <div class="license-value" id="email-value">${email}</div>
          <button class="copy-btn" data-target="email-value" type="button">コピー</button>
        </div>
      </div>
      <div class="license-row">
        <div class="license-label">ライセンスキー</div>
        <div class="license-value-row">
          <div class="license-value" id="key-value">${key}</div>
          <button class="copy-btn" data-target="key-value" type="button">コピー</button>
        </div>
      </div>
    </div>

    <p class="email-notice ${emailSent ? "" : "warn"}">
      ${emailSent
        ? "同じ内容をご登録のメールアドレスにもお送りしました。届かない場合は迷惑メールフォルダもご確認ください。"
        : "メール送信に失敗しているか、配信が遅れています。このページのキーを必ず保管してください。"}
    </p>

    <div class="steps">
      <h2>アクティベート手順</h2>
      <ol>
        <li>PolePole を起動します。</li>
        <li>メニューバーの <strong>PolePole → 設定</strong> (<kbd>⌘</kbd> + <kbd>,</kbd>) を開き、<strong>License</strong> タブを選択します。</li>
        <li>上記のメールアドレスとライセンスキーを貼り付け、<strong>アクティベート</strong> をクリックします。</li>
      </ol>
    </div>

    <div class="notes">
      <ul>
        <li>1 ライセンスにつき 3 台までアクティベートできます</li>
        <li>全メジャーバージョン無料アップデート (Lifetime License)</li>
        <li>ご不明点は <a href="https://polepole.dev/contact">お問い合わせフォーム</a> までどうぞ</li>
      </ul>
    </div>

    <div class="thanks-footer">
      <a href="https://polepole.dev/" class="btn btn-secondary">polepole.dev に戻る</a>
    </div>
  </div>

  <script>
    document.querySelectorAll('.copy-btn').forEach(function (btn) {
      btn.addEventListener('click', async function () {
        var target = document.getElementById(btn.dataset.target);
        if (!target) return;
        try {
          await navigator.clipboard.writeText(target.textContent.trim());
        } catch (e) {
          // フォールバック: 選択して execCommand
          var range = document.createRange();
          range.selectNode(target);
          var sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(range);
          try { document.execCommand('copy'); } catch (_) {}
          sel.removeAllRanges();
        }
        var orig = btn.textContent;
        btn.textContent = 'コピーしました';
        btn.classList.add('copied');
        setTimeout(function () {
          btn.textContent = orig;
          btn.classList.remove('copied');
        }, 1500);
      });
    });
  </script>
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
