#!/usr/bin/env bash
# AppIcon.appiconset を Resources/Assets.xcassets/ に生成する。
# - 1024x1024 のマスター PNG を Swift スクリプトで描画
# - sips で 10 サイズに resize
# - Contents.json を出力
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_SCRIPT="$ROOT/scripts/generate-app-icon.swift"
ASSETS_DIR="$ROOT/Resources/Assets.xcassets"
ICONSET_DIR="$ASSETS_DIR/AppIcon.appiconset"
TMP_MASTER="$(mktemp -t ide-icon-master).png"

mkdir -p "$ICONSET_DIR"
mkdir -p "$ASSETS_DIR"

# Assets.xcassets ルートの Contents.json（無ければ作る）
if [ ! -f "$ASSETS_DIR/Contents.json" ]; then
  cat > "$ASSETS_DIR/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
fi

echo "==> render master 1024x1024"
swift "$SWIFT_SCRIPT" "$TMP_MASTER" 1024

# size_label, scale, pixel_size, filename
ENTRIES=(
  "16  1 16   16.png"
  "16  2 32   16@2x.png"
  "32  1 32   32.png"
  "32  2 64   32@2x.png"
  "128 1 128  128.png"
  "128 2 256  128@2x.png"
  "256 1 256  256.png"
  "256 2 512  256@2x.png"
  "512 1 512  512.png"
  "512 2 1024 512@2x.png"
)

echo "==> resize"
for entry in "${ENTRIES[@]}"; do
  read -r _label _scale px file <<<"$entry"
  out="$ICONSET_DIR/$file"
  if [ "$px" = "1024" ]; then
    cp "$TMP_MASTER" "$out"
  else
    sips -s format png -z "$px" "$px" "$TMP_MASTER" --out "$out" >/dev/null
  fi
done

echo "==> write Contents.json"
cat > "$ICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "512@2x.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

rm -f "$TMP_MASTER"
echo "done: $ICONSET_DIR"
