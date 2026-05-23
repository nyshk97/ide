#!/usr/bin/env bash
# PolePole ライセンス署名用の EdDSA (Ed25519) 鍵ペアを生成する。
# Sparkle のアプリ署名鍵とは別鍵。漏洩時の被害切り分けのため。
#
# 出力:
#   - <dotfiles>/secrets/polepole/license-signing-private.pem  (Workers env / GitHub Gist など秘匿先に投入)
#   - <repo>/Resources/License/license-pubkey.pem               (アプリにバンドル、git に commit OK)
#
# 既存ファイルがあると上書き禁止 (鍵を作り直すと既存ユーザーのトークンが全部 invalid になる)。
# 本気で作り直したい場合は --force を付ける。

set -euo pipefail

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/Library/CloudStorage/Dropbox/dotfiles}"
SECRET_DIR="$DOTFILES_DIR/secrets/polepole"
PRIVATE_KEY_PATH="$SECRET_DIR/license-signing-private.pem"
PUBLIC_KEY_DIR="$REPO_ROOT/Resources/License"
PUBLIC_KEY_PATH="$PUBLIC_KEY_DIR/license-pubkey.pem"

if [[ -f "$PRIVATE_KEY_PATH" && "$FORCE" -ne 1 ]]; then
  echo "ERROR: $PRIVATE_KEY_PATH already exists." >&2
  echo "Regenerating the key will invalidate every license token issued so far." >&2
  echo "Pass --force only if you really mean it." >&2
  exit 1
fi

if [[ -f "$PUBLIC_KEY_PATH" && "$FORCE" -ne 1 ]]; then
  echo "ERROR: $PUBLIC_KEY_PATH already exists." >&2
  echo "Pass --force only if you really mean it." >&2
  exit 1
fi

mkdir -p "$SECRET_DIR"
mkdir -p "$PUBLIC_KEY_DIR"

OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
if ! "$OPENSSL_BIN" version >/dev/null 2>&1; then
  echo "ERROR: openssl not found. Install via 'brew install openssl@3' and re-run." >&2
  exit 1
fi

echo "Generating Ed25519 private key -> $PRIVATE_KEY_PATH"
"$OPENSSL_BIN" genpkey -algorithm ED25519 -out "$PRIVATE_KEY_PATH"
chmod 600 "$PRIVATE_KEY_PATH"

echo "Extracting public key -> $PUBLIC_KEY_PATH"
"$OPENSSL_BIN" pkey -in "$PRIVATE_KEY_PATH" -pubout -out "$PUBLIC_KEY_PATH"
chmod 644 "$PUBLIC_KEY_PATH"

echo ""
echo "Done."
echo ""
echo "Next steps:"
echo "  1. Inject the private key into Cloudflare Workers env:"
echo "       cd backend && pnpm wrangler secret put LICENSE_SIGNING_PRIVATE_KEY < $PRIVATE_KEY_PATH"
echo "  2. For local dev (wrangler dev --local), copy the contents into backend/.dev.vars as:"
echo "       LICENSE_SIGNING_PRIVATE_KEY=\"\$(cat $PRIVATE_KEY_PATH)\""
echo "     (use a single-line escaped form; .dev.vars is gitignored)"
echo "  3. The public key at $PUBLIC_KEY_PATH should be committed to git so the app bundle picks it up."
