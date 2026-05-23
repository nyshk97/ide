#!/usr/bin/env bash
# PolePole 用の Stripe Sandbox (or Test mode) に Product / Price / Payment Link を作る。
# 冪等ではないので、複数回流すと同名の Product / Price / Payment Link が増える。
# 通常は Sandbox を新規作成した直後に 1 回だけ実行する。
#
# 使い方:
#   export STRIPE_SK=sk_test_xxxxxxxx   # Sandbox のシークレットキー
#   bash backend/scripts/setup-stripe-products.sh
#
# Live mode の sk_live_... を渡さないこと。スクリプトは確認しないので、呼び出し側の責任。

set -euo pipefail

if [[ -z "${STRIPE_SK:-}" ]]; then
  echo "ERROR: STRIPE_SK is not set." >&2
  echo "  Get it from Stripe Dashboard (Sandbox) -> Developers -> API keys -> Secret key" >&2
  echo "  Then: export STRIPE_SK=sk_test_xxxxxxxx" >&2
  exit 1
fi

if [[ "$STRIPE_SK" != sk_test_* ]]; then
  echo "ERROR: STRIPE_SK must start with 'sk_test_' (Sandbox/Test mode key)." >&2
  echo "  Refusing to run against a live key." >&2
  exit 1
fi

if ! command -v stripe >/dev/null 2>&1; then
  echo "ERROR: stripe CLI not found. Install via 'brew install stripe/stripe-cli/stripe'." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found. Install via 'brew install jq'." >&2
  exit 1
fi

PRODUCT_NAME="PolePole Lifetime License"
PRODUCT_DESCRIPTION="PolePole の全機能をすべてのメジャーバージョンで利用できる永続ライセンス"
AMOUNT=11800
CURRENCY=jpy
SUCCESS_URL="https://polepole.dev/thanks?session_id={CHECKOUT_SESSION_ID}"

echo "==> Creating Product"
PRODUCT_JSON=$(stripe products create \
  --api-key "$STRIPE_SK" \
  -d "name=$PRODUCT_NAME" \
  -d "description=$PRODUCT_DESCRIPTION")
PRODUCT_ID=$(echo "$PRODUCT_JSON" | jq -r .id)
echo "    product: $PRODUCT_ID"

echo "==> Creating Price (¥$AMOUNT $CURRENCY)"
PRICE_JSON=$(stripe prices create \
  --api-key "$STRIPE_SK" \
  -d "product=$PRODUCT_ID" \
  -d "unit_amount=$AMOUNT" \
  -d "currency=$CURRENCY")
PRICE_ID=$(echo "$PRICE_JSON" | jq -r .id)
echo "    price:   $PRICE_ID"

echo "==> Creating Payment Link (card only, redirect to thanks page)"
LINK_JSON=$(stripe payment_links create \
  --api-key "$STRIPE_SK" \
  -d "line_items[0][price]=$PRICE_ID" \
  -d "line_items[0][quantity]=1" \
  -d "payment_method_types[0]=card" \
  -d "after_completion[type]=redirect" \
  -d "after_completion[redirect][url]=$SUCCESS_URL")
LINK_ID=$(echo "$LINK_JSON" | jq -r .id)
LINK_URL=$(echo "$LINK_JSON" | jq -r .url)
echo "    link id: $LINK_ID"
echo "    link url: $LINK_URL"

cat <<EOF

================================================================
Done. Append these to backend/.dev.vars:

    STRIPE_SECRET_KEY="$STRIPE_SK"
    EXPECTED_PRICE_ID="$PRICE_ID"
    EXPECTED_PAYMENT_LINK_ID="$LINK_ID"

Payment Link URL (open in browser to test-purchase with Stripe test card 4242 4242 4242 4242):
    $LINK_URL
================================================================
EOF
