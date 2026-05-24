---
build-info: docs/CHANGELOG.md は source-of-truth。public site の /changelog と /en/changelog は backend/scripts/build-changelog.mjs がここから生成する。release.sh が [Unreleased] を [X.Y.Z] - YYYY-MM-DD にリネームし、該当 section を GitHub Release notes と Sparkle appcast の <description> に注入する。
---

# Changelog

PolePole の更新履歴。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) ベース、バージョニングは [SemVer](https://semver.org/lang/ja/)。

## 書き方

各 list item は同じ変更を `ja:` と `en:` の 2 行で並列に書く。build script はこの prefix で振り分けて `/changelog` (JP) と `/en/changelog` (EN) 両方を生成する。

```markdown
### ✨ Added
- ja: 機能 A を追加
- en: Added feature A
```

長めの説明が要るときは list item にインデントして 1〜数行で書ける (`ja:` 行の直下に `  - ja: 詳細...` 不要。`  詳細...` でも OK)。動画/画像は今は埋め込まない (将来検討)。

カテゴリは以下から選ぶ:

- `✨ Added` — 新機能
- `📝 Changed` — 既存機能の挙動変更 / 改善
- `🐛 Fixed` — バグ修正
- `🗑️ Removed` — 機能削除
- `🔒 Security` — セキュリティ修正
- `⚠️ Deprecated` — 将来削除予定の告知

「内部リファクタ」「ドキュメント追加」「CI 調整」などユーザー目視で気づかない変更は **書かない**。

## [Unreleased]

## [1.1.2] - 2026-05-24
### ✨ Added
- ja: 公式サイトに [/guide](https://polepole.dev/guide) ページを追加 (初回起動・ライセンス適用・アップデート・Ghostty 設定の早見表)
- en: Added a new [/guide](https://polepole.dev/guide) page on the official site, covering first launch, license activation, updates, and Ghostty configuration

### 📝 Changed
- ja: Cmd+P (ファイル名検索) と Cmd+Shift+F (全文検索) で、`.gitignore` を持たないプロジェクトでも `node_modules` / `target` / `__pycache__` / `dist` / `vendor` / `.next` などの典型的なディレクトリを常に検索対象から除外するようにしました
- en: Cmd+P (file search) and Cmd+Shift+F (full-text search) now always exclude common build/vendor/cache directories (`node_modules`, `target`, `__pycache__`, `dist`, `vendor`, `.next`, etc.) even when the project has no `.gitignore`
- ja: ファイルツリーの reload ボタン・preview ↔ tree 切替ボタン・`.gitignored` 表示トグルに、Git ボタンと同じホバー背景を付けて操作可能な要素であることを分かりやすくしました
- en: The reload button, preview ↔ tree toggle, and the hide-ignored toggle in the file tree now share the same hover background as the Git button, making them feel more clearly clickable
- ja: ファイルツリーを reload した後も、開いていたディレクトリの展開状態を保持するようにしました
- en: The file tree now keeps each directory's expand state across reloads

### 🗑️ Removed
- ja: Cmd+P 検索オーバーレイの「ignored を含む」トグルボタンを削除しました (常に除外する挙動に統一)
- en: Removed the "include ignored" toggle button from the Cmd+P overlay (it now always excludes ignored entries)

## [1.1.1] - 2026-05-24
### 📝 Changed
- ja: トライアル期限切れ画面 (ペイウォール) を整理。アプリアイコンを表示し、価格表記を公式サイトと同じ ¥9,900 に統一、レイアウトの余白を調整しました
- en: Polished the trial-expiry paywall: shows the app icon, matches the website's ¥9,900 price, and tightened the layout spacing
- ja: ご購入後のライセンス受け取りページを刷新。アプリアイコン・ライセンスキーのコピーボタン・3 ステップのアクティベートガイドを追加しました
- en: Redesigned the post-purchase license page with the app icon, copy-to-clipboard buttons, and a 3-step activation guide

### 🗑️ Removed
- ja: ペイウォールの「ライセンスキーを再送」ボタンを削除しました (紛失時はお問い合わせフォームからご連絡ください)
- en: Removed the "Resend license key" button from the paywall (please use the contact form if you lose your key)

## [1.1.0] - 2026-05-24
### ✨ Added
- ja: ライセンス購入フローを追加。14 日無料トライアル → Stripe で決済 → メールで届くライセンスキーでアクティベーション
- en: Added license purchase flow: 14-day free trial → Stripe checkout → activate with the license key delivered by email
- ja: トライアル期限切れ後の起動ロック画面を追加。期限切れ後はライセンスを入れるまで起動できない
- en: Added an expiry lock screen after the trial period; the app stays locked until a license key is entered
- ja: 公式サイト [polepole.dev](https://polepole.dev) を公開 (LP + プライバシーポリシー + 利用規約 + 特定商取引法)
- en: Launched the official site at [polepole.dev](https://polepole.dev) with landing page, privacy policy, terms, and Japanese commercial-disclosure page
- ja: 問い合わせフォームを公式サイトに追加 (HyperForm 連携)
- en: Added a contact form on the official site (backed by HyperForm)
- ja: 公式サイトを英語対応 (現時点では `/en/` 配下はスタブ + 言語スイッチ。本翻訳は近日)
- en: Added i18n scaffolding for the official site; `/en/` pages are currently stubs with a language switcher, full translations coming soon

### 📝 Changed
- ja: LP の hero CTA を「無料で試す」+「価格を見る」に整理。購入ボタンも「ライセンスを購入する」に統一
- en: Reorganized the LP hero CTAs to "Try for free" + "See pricing", and unified the purchase buttons to "Buy a license"

## [1.0.0] - 2026-05-23

### 📝 Changed
- ja: `ide` から **PolePole** にリブランド (これ以前は `ide` という名前で内部開発)。Bundle ID は `local.d0ne1s.polepole` (Debug ビルドは `.dev` suffix)
- en: Rebranded from `ide` to **PolePole** (previously developed internally as `ide`). Bundle ID is now `local.d0ne1s.polepole` (Debug builds use a `.dev` suffix)
- ja: アプリアイコンを刷新 (青グラデ背景に象のアイコン)
- en: Refreshed the app icon (elephant icon on a blue gradient background)

---

旧 `ide` 時代 (v0.0.1〜v1.0.14, 2026-05-01〜2026-05-23) の履歴は GitHub Releases の [nyshk97/ide releases](https://github.com/nyshk97/ide/releases) を参照。Sparkle 配信の凍結履歴として残しています。
