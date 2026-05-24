// Resend で送るメールのテンプレ集約。
// 3 種類:
//   1. buildLicenseKeyEmail        — 購入直後の発行メール (fulfillment.ts から呼ばれる)
//   2. buildLicenseResendEmail     — 紛失時の再送メール (license.ts /v1/license/resend から呼ばれる)
//   3. buildUniversalTokenEmail    — サービス終了時のオフライン トークン配布メール (将来用、本 Phase ではテンプレのみ)
//
// 各関数とも HTML + text 両方を返す。HTML はインライン CSS (Apple-like minimal) で、
// Resend / Gmail / Apple Mail で素直に描画される範囲に留める。

import type { License } from "../types";
import type { ResendEmail } from "./resend";

const FROM = "PolePole <noreply@polepole.dev>";
const CONTACT_URL = "https://polepole.dev/contact";
const SITE_URL = "https://polepole.dev";

// HTML の共通スタイル。
// max-width 560 で Gmail と Apple Mail の両方で読みやすい幅。
// SF / Hiragino を優先しつつ Windows でも見られる font-family。
const HTML_BODY_STYLE =
  'font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Yu Gothic UI", sans-serif;' +
  " line-height: 1.6; color: #1a1a1a; max-width: 560px; margin: 0 auto; padding: 32px 24px;";
const CARD_STYLE =
  "background: #f5f5f7; padding: 16px; border-radius: 8px; margin: 24px 0;";
const LABEL_STYLE = "font-size: 12px; color: #666; margin-bottom: 4px;";
const VALUE_STYLE =
  "font-family: ui-monospace, SFMono-Regular, monospace; font-size: 14px; word-break: break-all;";
const NOTE_STYLE = "font-size: 13px; color: #666;";

// ===== 1. 購入直後のキー発行メール =====

export function buildLicenseKeyEmail(license: License): ResendEmail {
  const subject = "【PolePole】ご購入ありがとうございます — ライセンスキーをお届けします";
  const html = `<!DOCTYPE html>
<html lang="ja">
<body style="${HTML_BODY_STYLE}">
  <h1 style="font-size: 20px;">PolePole をご購入いただきありがとうございます</h1>
  <p>ライセンスキーをお届けします。アプリの <strong>Settings → ライセンス</strong> タブで、購入時のメールアドレスとキーを入力してアクティベートしてください。</p>
  <div style="${CARD_STYLE}">
    <div style="${LABEL_STYLE}">メールアドレス</div>
    <div style="${VALUE_STYLE}">${license.email}</div>
    <div style="${LABEL_STYLE} margin-top: 12px;">ライセンスキー</div>
    <div style="${VALUE_STYLE}">${license.id}</div>
  </div>
  <h2 style="font-size: 16px; margin-top: 32px;">ご利用にあたって</h2>
  <p style="${NOTE_STYLE}">
    ・1 ライセンスにつき <strong>3 台まで</strong>アクティベートできます<br>
    ・全メジャーバージョン無料アップデート (Lifetime License)<br>
    ・トライアル中の方は、Settings から本キーを入力するだけで継続利用可能です<br>
    ・ご不明な点は <a href="${CONTACT_URL}">お問い合わせフォーム</a> よりお問い合わせください
  </p>
  <p style="${NOTE_STYLE} margin-top: 32px;">— PolePole / <a href="${SITE_URL}">${SITE_URL}</a></p>
</body>
</html>`;

  const text = `PolePole をご購入いただきありがとうございます。

ライセンスキーをお届けします。アプリの Settings → ライセンスタブで、購入時のメールアドレスとキーを入力してアクティベートしてください。

  メールアドレス: ${license.email}
  ライセンスキー: ${license.id}

ご利用にあたって:
  ・1 ライセンスにつき 3 台までアクティベートできます
  ・全メジャーバージョン無料アップデート (Lifetime License)
  ・トライアル中の方は、Settings から本キーを入力するだけで継続利用可能です
  ・ご不明な点は ${CONTACT_URL} よりお問い合わせください

— PolePole / ${SITE_URL}`;

  return { from: FROM, to: license.email, subject, html, text };
}

// ===== 2. 紛失時の再送メール =====
// 件名と冒頭文を「再送」のニュアンスに変更。本文の説明は購入直後と揃える
// (受け取った人は購入直後と同等の情報セットを欲しがる前提)。

export function buildLicenseResendEmail(license: License): ResendEmail {
  const subject = "【PolePole】ライセンスキーの再送";
  const html = `<!DOCTYPE html>
<html lang="ja">
<body style="${HTML_BODY_STYLE}">
  <h1 style="font-size: 20px;">ライセンスキーを再送します</h1>
  <p>ご請求いただいたライセンスキーをお送りします。アプリの <strong>Settings → ライセンス</strong> タブで、メールアドレスとキーを入力してアクティベートしてください。</p>
  <div style="${CARD_STYLE}">
    <div style="${LABEL_STYLE}">メールアドレス</div>
    <div style="${VALUE_STYLE}">${license.email}</div>
    <div style="${LABEL_STYLE} margin-top: 12px;">ライセンスキー</div>
    <div style="${VALUE_STYLE}">${license.id}</div>
  </div>
  <p style="${NOTE_STYLE}">
    本メールにお心当たりがない場合は、第三者がお客様のメールアドレスで再送リクエストを行った可能性があります。お手数ですが本メールは破棄してください (キー自体はメールアドレスとセットでなければアクティベートできません)。
  </p>
  <h2 style="font-size: 16px; margin-top: 32px;">ご利用にあたって</h2>
  <p style="${NOTE_STYLE}">
    ・1 ライセンスにつき 3 台までアクティベートできます<br>
    ・既存のアクティベート状況は維持されています (本メールはキー送付のみ)<br>
    ・ご不明な点は <a href="${CONTACT_URL}">お問い合わせフォーム</a> よりお問い合わせください
  </p>
  <p style="${NOTE_STYLE} margin-top: 32px;">— PolePole / <a href="${SITE_URL}">${SITE_URL}</a></p>
</body>
</html>`;

  const text = `ライセンスキーを再送します。

ご請求いただいたライセンスキーをお送りします。アプリの Settings → ライセンスタブで、メールアドレスとキーを入力してアクティベートしてください。

  メールアドレス: ${license.email}
  ライセンスキー: ${license.id}

本メールにお心当たりがない場合は、第三者がお客様のメールアドレスで再送リクエストを行った可能性があります。お手数ですが本メールは破棄してください (キー自体はメールアドレスとセットでなければアクティベートできません)。

ご利用にあたって:
  ・1 ライセンスにつき 3 台までアクティベートできます
  ・既存のアクティベート状況は維持されています (本メールはキー送付のみ)
  ・ご不明な点は ${CONTACT_URL} よりお問い合わせください

— PolePole / ${SITE_URL}`;

  return { from: FROM, to: license.email, subject, html, text };
}

// ===== 3. (将来用) サ終時 universal token 配信メール ひな型 =====
// service-shutdown 90 日前にユーザーに配布する想定。本 Phase では送信ロジックは
// 用意せず、テンプレ生成関数だけ置く。実行は将来「offline 秘密鍵で署名 → このテンプレで
// 全 active ライセンスに送信」のスクリプトを用意したときに使う。

export type UniversalTokenEmailArgs = {
  email: string;          // 送付先 (= 購入時 email)
  licenseKey: string;     // ユーザーのライセンスキー (表示用)
  universalToken: string; // オフライン秘密鍵で署名した universal token (本体)
  shutdownDate: string;   // サービス終了予定日 (例: "2030-12-31")
};

export function buildUniversalTokenEmail(args: UniversalTokenEmailArgs): ResendEmail {
  const subject = "【重要】PolePole サービス終了のお知らせとオフライン トークンのご案内";
  const html = `<!DOCTYPE html>
<html lang="ja">
<body style="${HTML_BODY_STYLE}">
  <h1 style="font-size: 20px;">PolePole サービス終了のお知らせ</h1>
  <p>いつも PolePole をご利用いただきありがとうございます。</p>
  <p>誠に勝手ながら、PolePole のライセンス検証サービスを <strong>${args.shutdownDate}</strong> をもって終了することとなりました。</p>
  <h2 style="font-size: 16px;">既存ユーザーへの救済</h2>
  <p>サービス終了後も既存ライセンスを継続してご利用いただけるよう、<strong>オフライン トークン (universal token)</strong> をお送りします。下記のトークンをアプリに取り込むことで、本アプリは検証サーバーへの問い合わせなしに動作するようになります。</p>
  <div style="${CARD_STYLE}">
    <div style="${LABEL_STYLE}">ライセンスキー</div>
    <div style="${VALUE_STYLE}">${args.licenseKey}</div>
    <div style="${LABEL_STYLE} margin-top: 12px;">オフライン トークン (universal token)</div>
    <div style="${VALUE_STYLE}">${args.universalToken}</div>
  </div>
  <h2 style="font-size: 16px;">取り込み手順</h2>
  <p style="${NOTE_STYLE}">
    ・PolePole アプリの最新版 (サービス終了対応版) にアップデートしてください<br>
    ・<strong>Settings → ライセンス</strong> タブの「オフライン トークンを取り込む」から上記トークンを貼り付け<br>
    ・取り込み後は再アクティベート不要で、引き続き全機能をご利用いただけます
  </p>
  <h2 style="font-size: 16px;">よくあるご質問</h2>
  <p style="${NOTE_STYLE}">
    <strong>Q. このトークンを他人に渡しても良い?</strong><br>
    A. 渡さないでください。本トークンは購入者ごとに固有で、サポートおよび誤利用追跡の手がかりになります。<br><br>
    <strong>Q. 端末を買い替えた場合は?</strong><br>
    A. 本メールを保管しておけば、新しい端末でも同じトークンで取り込みできます。3 台までの上限は廃止されます。<br><br>
    <strong>Q. アプリのアップデートはどうなる?</strong><br>
    A. サービス終了後は新規アップデートを提供できなくなりますが、最終版は永続的にご利用いただけます。
  </p>
  <p style="${NOTE_STYLE}">
    本件に関するお問い合わせは <a href="${CONTACT_URL}">お問い合わせフォーム</a> よりお願いします。<br>
    長らくのご愛顧、誠にありがとうございました。
  </p>
  <p style="${NOTE_STYLE} margin-top: 32px;">— PolePole / <a href="${SITE_URL}">${SITE_URL}</a></p>
</body>
</html>`;

  const text = `PolePole サービス終了のお知らせ

いつも PolePole をご利用いただきありがとうございます。

誠に勝手ながら、PolePole のライセンス検証サービスを ${args.shutdownDate} をもって終了することとなりました。

【既存ユーザーへの救済】

サービス終了後も既存ライセンスを継続してご利用いただけるよう、オフライン トークン (universal token) をお送りします。下記のトークンをアプリに取り込むことで、本アプリは検証サーバーへの問い合わせなしに動作するようになります。

  ライセンスキー: ${args.licenseKey}
  オフライン トークン: ${args.universalToken}

【取り込み手順】

  ・PolePole アプリの最新版 (サービス終了対応版) にアップデートしてください
  ・Settings → ライセンスタブの「オフライン トークンを取り込む」から上記トークンを貼り付け
  ・取り込み後は再アクティベート不要で、引き続き全機能をご利用いただけます

【よくあるご質問】

  Q. このトークンを他人に渡しても良い?
  A. 渡さないでください。本トークンは購入者ごとに固有で、サポートおよび誤利用追跡の手がかりになります。

  Q. 端末を買い替えた場合は?
  A. 本メールを保管しておけば、新しい端末でも同じトークンで取り込みできます。3 台までの上限は廃止されます。

  Q. アプリのアップデートはどうなる?
  A. サービス終了後は新規アップデートを提供できなくなりますが、最終版は永続的にご利用いただけます。

本件に関するお問い合わせは ${CONTACT_URL} よりお願いします。
長らくのご愛顧、誠にありがとうございました。

— PolePole / ${SITE_URL}`;

  return { from: FROM, to: args.email, subject, html, text };
}
