#!/usr/bin/env bash
# PolePole ローンチ記念クーポン (ZENN50) を Stripe Test mode に作る。
#   - 割引:   50% OFF (percent_off=50, duration=once / 買い切り 1 回適用)
#   - 商品:   PRODUCT_ID で対象商品に限定 (applies_to)。新規 coupon 作成時は必須
#   - 希少性: 先着 50 名 (Promotion Code の max_redemptions=50 で 51 人目以降を弾く)
#   - 期限:   デフォルト 90 日 (Promotion Code の expires_at)。0 で無期限
#   - 流入元: Zenn 記事からの導線。媒体別に増やすなら COUPON_ID で同じ Coupon を使い回し
#             PROMO_CODE を変えて別 Promotion Code を足す
#
# 冪等ではない。Promotion Code は account 内で(active な範囲で)一意なので、
# 同じ PROMO_CODE で 2 回流すと code 重複でエラーになる (これは想定挙動)。
#
# 使い方:
#   export STRIPE_SK=sk_test_xxxxxxxx        # Test mode のシークレットキー (.dev.vars の STRIPE_SECRET_KEY)
#   export PRODUCT_ID=prod_xxxxxxxx          # 必須(新規 coupon 作成時)。割引対象の商品に限定する
#   bash backend/scripts/setup-stripe-coupon.sh
#
#   任意:
#   export COUPON_ID=xxxxxxxx                # 既存 Coupon を使い回す。指定時は coupon 作成をスキップ(PRODUCT_ID 不要)
#   export PROMO_CODE=ZENN50                 # 顧客が入力するコード (媒体別に変える)。default ZENN50
#   export PROMO_MAX_REDEMPTIONS=50          # この Promotion Code の上限。default 50
#   export PROMO_EXPIRES_DAYS=90             # 実行時点から N 日で失効。0 で無期限。default 90
#   export PROMO_FIRST_TIME_ONLY=true        # first_time_transaction 制約。default false (下記 P1 参照)
#   export PAYMENT_LINK_ID=plink_xxxxxxxx    # 指定すると Payment Link で promotion code 入力を有効化
#
# Live mode の sk_live_... を渡さないこと。スクリプトは sk_test_ 以外を拒否する。
#
# 設計メモ:
#   [P1] first_time_transaction は Payment Link では当てにできない。Payment Link の one-time
#        payment は毎回 guest Customer を作るため「初回購入限定」が実質 no-op になる
#        (https://docs.stripe.com/payment-links/promotions)。二重割引を確実に防ぐなら
#        Checkout Session + 既存 Customer 再利用の導線が要る。ここでの実質的な打ち止めは
#        Promotion Code の max_redemptions。first_time は気休めとして opt-in に留める
#   [P2] 期限なし × account-wide な Coupon は将来商品 ($79 海外 Price 等) にも残り続けるので、
#        新規作成時は applies_to を必須にして product scope する
#
# 既知の Stripe 落とし穴 (backend/DEPLOY.md 付録):
#   §A promotion_codes create は新版 API default だと `coupon` が parameter_unknown で reject される
#      → --stripe-version 2024-06-20 をピン留めして回避 (coupons / payment_links 側では発生しない)
#   §B payment_links update を `>` redirect / `$()` / tee で受けると CLI が hang する
#      → update だけ curl で REST を直叩きする (create 系は CLI の $() 受けで OK)

set -euo pipefail

if [[ -z "${STRIPE_SK:-}" ]]; then
  echo "ERROR: STRIPE_SK is not set." >&2
  echo "  export STRIPE_SK=\"\$(grep '^STRIPE_SECRET_KEY' backend/.dev.vars | sed -E 's/^STRIPE_SECRET_KEY=//; s/^\"//; s/\"\$//')\"" >&2
  exit 1
fi

if [[ "$STRIPE_SK" != sk_test_* ]]; then
  echo "ERROR: STRIPE_SK must start with 'sk_test_' (Test mode key)." >&2
  echo "  Refusing to run against a live key." >&2
  exit 1
fi

for cmd in stripe jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '$cmd' not found." >&2
    [[ "$cmd" == stripe ]] && echo "  Install via 'brew install stripe/stripe-cli/stripe'." >&2
    [[ "$cmd" == jq ]] && echo "  Install via 'brew install jq'." >&2
    exit 1
  fi
done

PROMO_CODE="${PROMO_CODE:-ZENN50}"
PERCENT_OFF="${PERCENT_OFF:-50}"
COUPON_NAME="PolePole ローンチ記念 — Zenn 50%OFF (先着50名)"
COUPON_ID="${COUPON_ID:-}"
PRODUCT_ID="${PRODUCT_ID:-}"
PAYMENT_LINK_ID="${PAYMENT_LINK_ID:-}"
PROMO_MAX_REDEMPTIONS="${PROMO_MAX_REDEMPTIONS:-50}"
PROMO_EXPIRES_DAYS="${PROMO_EXPIRES_DAYS:-90}"
PROMO_FIRST_TIME_ONLY="${PROMO_FIRST_TIME_ONLY:-false}"

if ! [[ "$PROMO_EXPIRES_DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: PROMO_EXPIRES_DAYS must be a non-negative integer (got '$PROMO_EXPIRES_DAYS')." >&2
  exit 1
fi

# --- Coupon: 新規作成 or 既存を使い回し -------------------------------------
if [[ -z "$COUPON_ID" ]]; then
  # [P2] 新規 coupon は product scope 必須
  if [[ -z "$PRODUCT_ID" ]]; then
    echo "ERROR: PRODUCT_ID is required when creating a new coupon (P2: product scope)." >&2
    echo "  対象商品に限定しないと、将来追加する別商品にもこの 50%OFF が効いてしまう。" >&2
    echo "  商品 ID を探す:  stripe products list --api-key \"\$STRIPE_SK\" --limit 5" >&2
    echo "  既存 Coupon を使い回す: export COUPON_ID=<id> (この場合 PRODUCT_ID 不要)" >&2
    exit 1
  fi
  # 注意: applies_to は API レスポンスに serialize されない (coupons retrieve しても出ない / 全 version)。
  #       制限が効いているかは「対象外商品に当てて 'does not apply to anything' で弾かれるか」で検証する。
  echo "==> Creating Coupon (percent_off=$PERCENT_OFF, duration=once, applies_to=$PRODUCT_ID)"
  COUPON_JSON=$(stripe coupons create \
    --api-key "$STRIPE_SK" \
    -d "percent_off=$PERCENT_OFF" \
    -d "duration=once" \
    -d "name=$COUPON_NAME" \
    -d "applies_to[products][0]=$PRODUCT_ID")
  COUPON_ID=$(echo "$COUPON_JSON" | jq -r .id)
  if [[ -z "$COUPON_ID" || "$COUPON_ID" == "null" ]]; then
    echo "ERROR: coupon creation failed." >&2
    echo "$COUPON_JSON" | jq -r '.error.message // .' >&2
    exit 1
  fi
  echo "    coupon: $COUPON_ID"
else
  echo "==> Reusing existing Coupon $COUPON_ID (skipping creation; PRODUCT_ID ignored)"
fi

# --- Promotion Code: 打ち止め(max_redemptions)と期限(expires_at)はこちらに乗せる ---
# §A: promotion_codes は --stripe-version をピン留めしないと coupon が parameter_unknown で落ちる
echo "==> Creating Promotion Code ($PROMO_CODE)"
PROMO_ARGS=(
  --api-key "$STRIPE_SK"
  --stripe-version 2024-06-20
  -d "coupon=$COUPON_ID"
  -d "code=$PROMO_CODE"
  -d "max_redemptions=$PROMO_MAX_REDEMPTIONS"
)
if [[ "$PROMO_EXPIRES_DAYS" != "0" ]]; then
  EXPIRES_AT=$(( $(date +%s) + PROMO_EXPIRES_DAYS * 86400 ))
  PROMO_ARGS+=(-d "expires_at=$EXPIRES_AT")
  echo "    expires_at=$EXPIRES_AT (約 ${PROMO_EXPIRES_DAYS} 日後)"
fi
if [[ "$PROMO_FIRST_TIME_ONLY" == "true" ]]; then
  # [P1] Payment Link では実質効かない。確実に効かせたいなら Checkout Session + Customer 再利用
  PROMO_ARGS+=(-d "restrictions[first_time_transaction]=true")
  echo "    restrictions[first_time_transaction]=true (注意: Payment Link では当てにならない / P1)"
fi
PROMO_JSON=$(stripe promotion_codes create "${PROMO_ARGS[@]}")
PROMO_ID=$(echo "$PROMO_JSON" | jq -r .id)
if [[ -z "$PROMO_ID" || "$PROMO_ID" == "null" ]]; then
  echo "ERROR: promotion code creation failed (coupon $COUPON_ID は作成済み)." >&2
  echo "$PROMO_JSON" | jq -r '.error.message // .' >&2
  exit 1
fi
PROMO_ACTIVE=$(echo "$PROMO_JSON" | jq -r .active)
echo "    promotion_code: $PROMO_ID (code=$PROMO_CODE active=$PROMO_ACTIVE max_redemptions=$PROMO_MAX_REDEMPTIONS)"

# --- Payment Link で promo code 入力欄を有効化 (任意) ------------------------
if [[ -n "$PAYMENT_LINK_ID" ]]; then
  # §B: payment_links update は CLI の redirect/$() 受けで hang するので curl で直叩き
  echo "==> Enabling promotion codes on Payment Link $PAYMENT_LINK_ID"
  PLINK_JSON=$(curl -sS -X POST -u "$STRIPE_SK:" \
    "https://api.stripe.com/v1/payment_links/$PAYMENT_LINK_ID" \
    -d "allow_promotion_codes=true")
  if [[ "$(echo "$PLINK_JSON" | jq -r '.allow_promotion_codes')" != "true" ]]; then
    echo "ERROR: failed to enable promotion codes on $PAYMENT_LINK_ID" >&2
    echo "$PLINK_JSON" | jq -r '.error.message // .' >&2
    exit 1
  fi
  echo "    allow_promotion_codes=true"
fi

cat <<EOF

================================================================
Done (Test mode).

  Coupon:          $COUPON_ID  ($PERCENT_OFF% OFF / once / product-scoped)
  Promotion Code:  $PROMO_CODE  ($PROMO_ID, max_redemptions=$PROMO_MAX_REDEMPTIONS)

顧客導線: Stripe Checkout / Payment Link の「プロモーションコード」欄に
          $PROMO_CODE を入力 -> $PERCENT_OFF% OFF (¥9,900 -> ¥4,950)、先着 $PROMO_MAX_REDEMPTIONS 名で打ち止め。

Live mode に作るときは sk_live_ キーで本スクリプトのガードを通らないため、
launch 直前に Stripe Dashboard か、ガードを外した別経路で作成する (本番反映は人間が確認してから)。
既存の product-scoped 50% Coupon があるなら COUPON_ID=<id> で使い回すと媒体別に計測しやすい。
================================================================
EOF
