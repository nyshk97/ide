#!/usr/bin/env bash
# build.sh で作った zip を GitHub Release として公開する。
# 使い方: scripts/release.sh <version>
#   例: scripts/release.sh 0.0.1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ZIP_PATH="$PROJECT_ROOT/build/ide.zip"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.0.1"
  exit 1
fi

VERSION="$1"
TAG="v$VERSION"

if [ ! -f "$ZIP_PATH" ]; then
  echo "==> build/ide.zip not found. Running build first..."
  "$SCRIPT_DIR/build.sh"
fi

echo "==> Creating GitHub release $TAG..."
gh release create "$TAG" \
  "$ZIP_PATH" \
  --title "$TAG" \
  --notes "ide $VERSION"

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo ""
echo "==> Release created: $TAG"
echo "==> SHA256: $SHA256"
echo ""
echo "Update homebrew-tap cask with:"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA256\""
