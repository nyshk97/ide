#!/usr/bin/env node
// docs/CHANGELOG.md から JP/EN の changelog HTML を生成する。
//   出力: backend/public/changelog.html, backend/public/en/changelog.html
//
// 各 list item は `- ja: ...` / `- en: ...` の2行で並列に書く規則。
// このスクリプトは prefix で振り分けてそれぞれの言語ページを作る。
//
// wrangler deploy 前のフックとして package.json の predeploy で叩く。

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");
const SRC = join(repoRoot, "docs/CHANGELOG.md");
const OUT_JP = join(repoRoot, "backend/public/changelog.html");
const OUT_EN = join(repoRoot, "backend/public/en/changelog.html");

// ===== Parse =====

function parse(md) {
  const lines = md.split("\n");
  const releases = [];
  let current = null;
  let currentCat = null;

  for (const line of lines) {
    const releaseMatch = line.match(/^## \[([^\]]+)\](?:\s*-\s*(.+))?\s*$/);
    if (releaseMatch) {
      current = {
        version: releaseMatch[1],
        date: releaseMatch[2]?.trim() || null,
        categories: [],
      };
      currentCat = null;
      releases.push(current);
      continue;
    }
    // 他の ## はリリース区切りのリセット（"書き方" など内部ドキュメント）
    if (/^## /.test(line)) {
      current = null;
      currentCat = null;
      continue;
    }
    if (!current) continue;

    const catMatch = line.match(/^### (.+?)\s*$/);
    if (catMatch) {
      currentCat = { title: catMatch[1], items: { ja: [], en: [] } };
      current.categories.push(currentCat);
      continue;
    }

    const itemMatch = line.match(/^-\s*(ja|en):\s*(.*)$/);
    if (itemMatch && currentCat) {
      currentCat.items[itemMatch[1]].push(itemMatch[2]);
      continue;
    }
  }

  return releases.filter((r) =>
    r.categories.some((c) => c.items.ja.length > 0 || c.items.en.length > 0)
  );
}

// ===== Render =====

const T = {
  ja: {
    title: "更新情報 — PolePole",
    description: "PolePole のリリース履歴。新機能・改善・修正の一覧。",
    h1: "更新情報",
    sub: "PolePole の最新リリースと変更履歴です。",
    sparkleNote:
      'アプリ内の「PolePole → Check for Updates…」から自動アップデートを受け取れます。',
    unreleased: "Unreleased",
    nav: { features: "特徴", pricing: "価格", download: "ダウンロード", changelog: "更新情報" },
    footer: {
      terms: "利用規約",
      privacy: "プライバシーポリシー",
      tokushoho: "特定商取引法に基づく表記",
      contact: "お問い合わせ",
      guide: "ガイド",
    },
    emptyNotice: "このリリースの日本語ノートはまだ準備中です。",
  },
  en: {
    title: "Changelog — PolePole",
    description: "PolePole release history. New features, improvements, and fixes.",
    h1: "Changelog",
    sub: "Latest releases and changes in PolePole.",
    sparkleNote:
      'Use "PolePole → Check for Updates…" in the app menu to receive auto-updates.',
    unreleased: "Unreleased",
    nav: { features: "Features", pricing: "Pricing", download: "Download", changelog: "Changelog" },
    footer: {
      terms: "Terms",
      privacy: "Privacy",
      tokushoho: null,
      contact: "Contact",
      guide: "Guide",
    },
    emptyNotice: "English notes for this release are not yet available.",
  },
};

function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// 限定的なインライン Markdown: `code`, **strong**, [label](url)
function inlineMd(text) {
  let s = escapeHtml(text);
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');
  return s;
}

function renderRelease(r, lang, t) {
  const isUnreleased = r.version.toLowerCase() === "unreleased";
  const versionLabel = isUnreleased ? t.unreleased : `v${r.version}`;

  const catsHtml = r.categories
    .map((cat) => {
      const items = cat.items[lang];
      if (!items || items.length === 0) return null;
      const lis = items.map((it) => `<li>${inlineMd(it)}</li>`).join("\n            ");
      return `        <div class="cl-category">
          <h3 class="cl-cat-title">${escapeHtml(cat.title)}</h3>
          <ul>
            ${lis}
          </ul>
        </div>`;
    })
    .filter(Boolean)
    .join("\n");

  if (!catsHtml) {
    return `      <article class="cl-release${isUnreleased ? " cl-unreleased" : ""}">
        <header class="cl-release-header">
          <span class="cl-version">${escapeHtml(versionLabel)}</span>
          ${r.date ? `<time class="cl-date">${escapeHtml(r.date)}</time>` : ""}
        </header>
        <p class="cl-empty">${t.emptyNotice}</p>
      </article>`;
  }

  return `      <article class="cl-release${isUnreleased ? " cl-unreleased" : ""}">
        <header class="cl-release-header">
          <span class="cl-version">${escapeHtml(versionLabel)}</span>
          ${r.date ? `<time class="cl-date">${escapeHtml(r.date)}</time>` : ""}
        </header>
${catsHtml}
      </article>`;
}

function renderPage(releases, lang) {
  const t = T[lang];
  const isJP = lang === "ja";
  const homeHref = isJP ? "/" : "/en/";
  const altHref = isJP ? "/en/changelog" : "/changelog";
  const selfHref = isJP ? "/changelog" : "/en/changelog";
  const canonical = `https://polepole.dev${selfHref}`;
  const langCurrent = isJP ? "JA" : "EN";
  const langOther = isJP ? "EN" : "JA";
  const robots = isJP ? "" : `<meta name="robots" content="noindex,follow">\n  `;

  const releasesHtml = releases.map((r) => renderRelease(r, lang, t)).join("\n");

  const footerLinks = isJP
    ? `<a href="/legal/terms">${t.footer.terms}</a>
        <a href="/legal/privacy">${t.footer.privacy}</a>
        <a href="/legal/tokushoho">${t.footer.tokushoho}</a>
        <a href="/contact">${t.footer.contact}</a>
        <a href="/guide">${t.footer.guide}</a>`
    : `<a href="/en/legal/terms">${t.footer.terms}</a>
        <a href="/en/legal/privacy">${t.footer.privacy}</a>
        <a href="/en/contact">${t.footer.contact}</a>
        <a href="/en/guide">${t.footer.guide}</a>`;

  return `<!DOCTYPE html>
<html lang="${lang}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  ${robots}<title>${t.title}</title>
  <meta name="description" content="${escapeHtml(t.description)}">
  <meta property="og:title" content="${escapeHtml(t.title)}">
  <meta property="og:description" content="${escapeHtml(t.description)}">
  <meta property="og:type" content="website">
  <meta property="og:url" content="${canonical}">
  <meta property="og:site_name" content="PolePole">
  <meta property="og:image" content="https://polepole.dev/og-image.jpg">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="${lang === "ja" ? "PolePole の画面 — ターミナル・ファイルプレビュー・プロジェクト切替をひとつのウィンドウで" : "PolePole — a macOS workspace for terminal-based AI coding CLIs"}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:image" content="https://polepole.dev/og-image.jpg">
  <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
  <link rel="icon" type="image/png" sizes="256x256" href="/app-icon.png">
  <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png">
  <link rel="canonical" href="${canonical}">
  <link rel="stylesheet" href="/styles.css">
</head>
<body>
  <header class="site-header">
    <div class="container">
      <a href="${homeHref}" class="logo">PolePole</a>
      <nav class="site-nav">
        <a href="${homeHref}#features">${t.nav.features}</a>
        <a href="${homeHref}#pricing">${t.nav.pricing}</a>
        <a href="${homeHref}#download">${t.nav.download}</a>
        <a href="${selfHref}" class="nav-active">${t.nav.changelog}</a>
        <span class="lang-switch">
          <span class="lang-current">${langCurrent}</span>
          <span class="lang-divider">·</span>
          <a href="${altHref}" class="lang-link">${langOther}</a>
        </span>
      </nav>
    </div>
  </header>

  <main class="changelog-page">
    <div class="container">
      <h1>${t.h1}</h1>
      <p class="changelog-intro">${t.sub}</p>
      <p class="changelog-sparkle-note">${t.sparkleNote}</p>

      <div class="cl-timeline">
${releasesHtml}
      </div>
    </div>
  </main>

  <footer class="site-footer">
    <div class="container">
      <div>
        ${footerLinks}
      </div>
      <div class="lang-switch">
        <span class="lang-current">${langCurrent}</span>
        <span class="lang-divider">·</span>
        <a href="${altHref}" class="lang-link">${langOther}</a>
      </div>
      <div class="copy">© 2026 PolePole</div>
    </div>
  </footer>
</body>
</html>
`;
}

// ===== Main =====

const md = await readFile(SRC, "utf8");
const releases = parse(md);

if (releases.length === 0) {
  console.error("ERROR: no releases parsed from CHANGELOG.md");
  process.exit(1);
}

await mkdir(dirname(OUT_EN), { recursive: true });
await writeFile(OUT_JP, renderPage(releases, "ja"));
await writeFile(OUT_EN, renderPage(releases, "en"));

console.log(`✓ Parsed ${releases.length} release(s) from CHANGELOG.md`);
console.log(`✓ Wrote ${OUT_JP}`);
console.log(`✓ Wrote ${OUT_EN}`);
