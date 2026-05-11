#!/usr/bin/env bash
# AppIcon.appiconset と AppIcon-Dev.appiconset を Resources/Assets.xcassets/ に生成する。
# - 1024x1024 のマスター PNG を Swift スクリプトで描画 (variant=release / dev で 2 種類)
# - sips で 10 サイズに resize
# - Contents.json を出力
#
# Debug ビルドは project.yml で ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Dev を指定。
# Release は AppIcon を使う。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_SCRIPT="$ROOT/scripts/generate-app-icon.swift"
ASSETS_DIR="$ROOT/Resources/Assets.xcassets"

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

# $1: iconset 名 (AppIcon / AppIcon-Dev)
# $2: Swift スクリプトに渡す variant (release / dev)
build_iconset() {
  local iconset_name="$1"
  local variant="$2"
  local iconset_dir="$ASSETS_DIR/$iconset_name.appiconset"
  local tmp_master
  tmp_master="$(mktemp -t ide-icon-master).png"
  mkdir -p "$iconset_dir"

  echo "==> [$iconset_name] render master 1024x1024 (variant=$variant)"
  swift "$SWIFT_SCRIPT" "$tmp_master" 1024 "$variant"

  echo "==> [$iconset_name] resize"
  for entry in "${ENTRIES[@]}"; do
    read -r _label _scale px file <<<"$entry"
    out="$iconset_dir/$file"
    if [ "$px" = "1024" ]; then
      cp "$tmp_master" "$out"
    else
      sips -s format png -z "$px" "$px" "$tmp_master" --out "$out" >/dev/null
    fi
  done

  echo "==> [$iconset_name] write Contents.json"
  cat > "$iconset_dir/Contents.json" <<'JSON'
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

  rm -f "$tmp_master"
  echo "done: $iconset_dir"
}

build_iconset "AppIcon"     "release"
build_iconset "AppIcon-Dev" "dev"
