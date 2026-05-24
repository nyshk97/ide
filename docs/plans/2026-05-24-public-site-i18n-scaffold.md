# public-site i18n scaffold

## 概要・やりたいこと

PolePole の公開サイト (`backend/public/` + Hono `/thanks`) はまだ日本語のみ。リリース 1 ヶ月後に海外展開を予定しているが、LP/購入導線のコピーは借り置きで今後ブラッシュアップを継続するため、**コピーの翻訳・key 化は今やらず、後から差し込めるよう URL/SEO/フォームの「土台」だけ先に入れる**。

スコープの内訳:

- **LP / Legal**: `/en/...` スタブ（"Coming soon" + JP へのリンク）を生やす。**hreflang は今回は張らない**（本翻訳投入時に有効化）。EN ページは `noindex,follow` で SEO に「同じ内容のローカライズ版」と誤認させない
- **Contact**: 英語フォーム（HyperForm 別 endpoint）を **本実装で先行**。海外からの問い合わせを今から受けられるようにする
- **Stripe**: dashboard で locale=auto を設定するだけ（コード変更なし）
- **`/thanks` (Hono)**: 当面 JP 固定。`?lang=` の受け口だけ仕込む

海外展開時は「`/en/` スタブを本翻訳に差し替える + `noindex` を外す + JP/EN 両方に hreflang を追加」の 1 セットで切り替え完了する状態にする。

## 前提・わかっていること

### サイト構成

- 対象は `backend/` (Cloudflare Workers + Hono、静的 HTML を `public/` から配信)
  - `public/index.html` (LP)
  - `public/contact.html` (HyperForm endpoint `tlzJV69s`)
  - `public/legal/{privacy,terms,tokushoho}.html`
  - `src/routes/thanks.ts` (Stripe success_url 受け、Hono で HTML レンダリング)
- アプリ UI 本体（macOS 側）は既に英語で実装済み。今回の対象外
- Stripe は固定 Payment Link (`https://buy.stripe.com/00w28q333cFyavN0pggrS00`)。locale は **Stripe Dashboard 側で `auto` 設定**するだけで対応（コード変更不要）

### `/dig-lite` で確定済みの設計判断

- **URL 構造**: ルート `/` = JP、`/en/` = EN（reverse は痛いため）
- **自動 redirect**: しない（SEO の Accept-Language redirect は Google が嫌う、cache key も汚れる）
- **EN ページ初期状態**: "English version coming soon" スタブ + JP ページへのリンク

### レビューで補強された前提

- **段階設計**: 今回は hreflang を **張らない** + EN スタブを `noindex,follow`。本翻訳投入時に「`noindex` 解除 + hreflang を JP/EN 両方に追加」を 1 セットで実施。スタブ段階で hreflang を張ると Google が「同じコンテンツのローカライズ版」と扱ってしまうため
- **tokushoho は JP-only**: 特定商取引法は日本国内取引向けの法定表記なので英語版を作らない。`/en/legal/tokushoho.html` は **作らない**。EN footer からも tokushoho リンクを外す。JP 側 tokushoho も将来的に hreflang en は **張らない**
- **EN → JP 戻りリンクはページ対応で**: `/en/contact` → `/contact`、`/en/legal/privacy` → `/legal/privacy` のように同階層に戻す（`/` に飛ばすと UX も hreflang 双方向性も崩れる）
- **Cloudflare Workers Assets の URL 正規化挙動**: `wrangler.toml` の `[assets]` は `html_handling` 未指定 = default `auto-trailing-slash`。`/foo.html` は `/foo` へ 301 redirect される。**canonical URL は extensionless**。新規追加するリンク（言語スイッチ、EN スタブから JP への戻り）はすべて extensionless で書く。既存 HTML 内の `.html` リンクは触らない（redirect 1 hop で動くので動作影響は無い）

### URL 対応表

| JP (canonical)        | EN (canonical)            | 備考                          |
| --------------------- | ------------------------- | ----------------------------- |
| `/`                   | `/en/`                    |                               |
| `/contact`            | `/en/contact`             | EN 側は HyperForm 別 endpoint |
| `/legal/privacy`      | `/en/legal/privacy`       | EN は stub                    |
| `/legal/terms`        | `/en/legal/terms`         | EN は stub                    |
| `/legal/tokushoho`    | (作らない)                | JP-only。hreflang en も無し   |

## 実装計画

### 事前準備 [人間👨‍💻]

- [x] HyperForm で英語問い合わせ用 form endpoint を新規作成し、endpoint ID を控える（既存 `tlzJV69s` と並列。返信メッセージ・自動返信メールも英語で設定）
  - 2026-05-24: `xAkLczSf` (PolePole[en] プロジェクト) として発行済み
- [ ] Stripe Dashboard で Payment Link `00w28q333cFyavN0pggrS00` の言語設定が「Auto-detect / Customer's language」になっているか確認。なっていなければそちらに変更
- [x] HyperForm 英語 endpoint ID を AI に共有 → `backend/public/en/contact.html` に反映済み

### Phase 1: JP ページに言語スイッチ slot を追加 [AI🤖]

> hreflang は **張らない**（段階設計）。本翻訳投入時に別途。今回は言語スイッチ UI と canonical 整備だけ。

- [x] `public/index.html` `public/contact.html` `public/legal/{privacy,terms,tokushoho}.html` のヘッダー `.site-nav` 末尾に JP/EN 言語スイッチを追加
  - JP active 表示、EN リンクは同階層の `/en/...` を指す（extensionless）
  - **tokushoho の言語スイッチは「JP のみ」表示**（EN ページが無いため、EN リンクを出さない or disabled で表示）
- [x] フッターにも同じスイッチを置く（モバイル fallback）
- [x] `styles.css` に言語スイッチ用クラス（active 表示、divider、サイズ、disabled）を追記
- [x] 各 JP ページに `<link rel="canonical" href="https://polepole.dev/...">` (extensionless) を追加。OG タグの URL も canonical に揃える

### Phase 2: EN スタブページ生成 [AI🤖]

- [x] `backend/public/en/` ディレクトリを新設
- [x] 共通スタブ仕様:
  - `<html lang="en">`
  - `<meta name="robots" content="noindex,follow">` （**必須**: スタブを Google にインデックスさせない）
  - `<link rel="canonical" href="https://polepole.dev/en/...">` （extensionless）
  - 共通ヘッダー/フッター英語化（ナビ項目、フッターリンクラベル）
  - ヘッダー言語スイッチ: EN active、JP リンクは **自 URL から `/en` を除いた path** を指す（`/en/contact` → `/contact`、`/en/legal/privacy` → `/legal/privacy`）
  - hreflang は **張らない**
- [x] `en/index.html`
  - body: "English version coming soon. The Japanese version is available below." + JP `/` への大きな CTA
  - 価格・ダウンロード・Stripe ボタンも一旦 JP `/` へのリンクで誘導
- [x] `en/contact.html` （HyperForm endpoint `xAkLczSf` に差し替え済み）
  - HyperForm `action` は **Phase 0 で取得した英語 endpoint** を使う（フォームラベルも英語）
  - フォーム上部に「Please write your inquiry in English.」
  - これは「本実装」: スタブではなく実フォームとして機能させる
- [x] `en/legal/privacy.html` `en/legal/terms.html`
  - "Coming soon" スタブ
  - 「The Japanese version is the authoritative version. English translation is in progress.」と明記（法務リスク回避）
  - JP 該当ページ (`/legal/privacy` / `/legal/terms`) への canonical リンクを本文中に置く
- [x] `en/legal/tokushoho.html` は **作らない**。EN footer のリンクリストからも tokushoho を除外

### Phase 3: Hono `/thanks` に locale 受け口だけ仕込む [AI🤖]

- [x] `src/routes/thanks.ts` で `const lang = c.req.query("lang") === "en" ? "en" : "ja";` を冒頭で読む
- [x] 当面は `lang === "ja"` のときの既存 HTML をそのまま返す
- [x] `lang === "en"` の分岐は TODO コメントで「Phase: 本翻訳時に EN HTML を生やす。Stripe 側 success_url にも `?lang=en` を埋め込む（EN 用 Payment Link 作成時に対応）」と明記
- [x] エラーページ (`errorPage`) も同様に lang を受けるシグネチャだけ追加、中身は JP 固定

### 動作確認 [AI🤖 + 人間👨‍💻]

#### A. canonical URL の HTTP / HTML 検証 [AI]

`cd backend && pnpm wrangler dev` で起動。以下を **canonical (extensionless) URL** に対して `curl -i` で叩き、ステータス 200 + `<html lang>` + canonical タグを確認:

- [x] JP: `/` `/contact` `/legal/privacy` `/legal/terms` `/legal/tokushoho`
  - `<html lang="ja">` であること
  - `<link rel="canonical" href="...">` が自 URL を指していること
  - hreflang タグは **無い** こと（段階設計）
- [x] EN: `/en/` `/en/contact` `/en/legal/privacy` `/en/legal/terms`
  - `<html lang="en">` であること
  - `<meta name="robots" content="noindex,follow">` があること
  - canonical が自 URL を指していること
- [x] EN 404: `/en/legal/tokushoho` → 404

#### B. `.html` URL の redirect 検証 [AI]

Cloudflare Assets default で `.html` → extensionless に 301 されることを確認:

- [x] `curl -i /legal/privacy.html` → 307 で `Location: /legal/privacy` を返すこと（200 で本文が返ってきたら設定がおかしい。実測 Cloudflare default は 307）
- [x] 同様に `/legal/terms.html` `/contact.html` `/en/contact.html` `/en/legal/privacy.html` も 307 確認

#### C. リンク整合性 [AI]

- [x] JP 全ページの言語スイッチが `/en/<対応 path>` を指していることを grep で確認（tokushoho は例外: EN リンク無し / disabled）
- [x] EN 全ページの言語スイッチが JP の `/<対応 path>` を指していることを grep で確認
- [x] EN footer に tokushoho リンクが含まれていないことを grep で確認

#### D. `/thanks` ロケール受け口 [AI]

- [x] dev サーバに lang 無し / `?lang=en` の両方で叩いて、どちらも JP HTML が返ることを確認（中身分岐は未実装で OK、シグネチャだけ。実測 bodies が identical）

#### E. 目視確認 [人間]

- [ ] ブラウザで `/` を開き、ヘッダーの EN スイッチをクリック → `/en/` のスタブが表示されることを目視
- [ ] `/en/contact` の言語スイッチをクリック → `/contact`（`/` ではない）に戻ることを確認
- [ ] `/en/contact` で英語 HyperForm にテスト送信 1 件、英語の自動返信が届くことを確認
- [ ] Stripe Payment Link を実際に開き、ブラウザ言語を英語にすると Checkout 画面が英語表記になることを確認

## ログ

### 試したこと・わかったこと

- 2026-05-24: Phase 1/2/3 実装 + 動作確認 A〜D を `pnpm wrangler dev --local --port 8788` で実行、全 pass:
  - A: JP 5 ページ 200 + lang=ja + canonical 一致 + hreflang **無し** (Phase 1 段階設計通り)
  - A: EN 4 ページ 200 + lang=en + canonical 一致 + `noindex,follow`
  - A: `/en/legal/tokushoho` → 404 ✓
  - B: `.html` 全 6 URL が **307** で extensionless へ redirect (Cloudflare Workers Assets の default `auto-trailing-slash` 挙動を確認)
  - C: JP/EN 双方の lang-switch が同階層の対応 path を指す。tokushoho EN は `.lang-disabled` で表示
  - D: `/thanks` `/thanks?lang=en` ともに JP HTML 400 を返す (slot だけで分岐未実装、bodies は identical)
- `pnpm typecheck` 通過
- Cloudflare Workers Assets の `.html` redirect ステータスは想定の 301/308 ではなく **307** が返った。挙動は同等 (extensionless にリダイレクト) なので OK

### 方針変更

- 2026-05-24: EN contact form の HyperForm endpoint を `xAkLczSf` (PolePole[en] プロジェクト) に差し替え。残るは Stripe Dashboard の locale 設定確認 + 人間目視確認のみ
