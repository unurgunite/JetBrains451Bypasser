#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/assets"
ICONSET="$ASSETS/jb_updater.iconset"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

SIZES=(16 32 128 256 512)
for s in "${SIZES[@]}"; do
  rsvg-convert -w "$s" -h "$s" "$ASSETS/jb_updater.svg" -o "$ICONSET/icon_${s}x${s}.png"
  rsvg-convert -w "$((s*2))" -h "$((s*2))" "$ASSETS/jb_updater.svg" -o "$ICONSET/icon_${s}x${s}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$ASSETS/jb_updater.icns"

rm -rf "$ICONSET"

for s in 16 32 48 128 256 512; do
  rsvg-convert -w "$s" -h "$s" "$ASSETS/jb_updater.svg" -o "$ASSETS/jb_updater_${s}x${s}.png"
done

magick "$ASSETS/jb_updater_256x256.png" "$ASSETS/jb_updater_48x48.png" \
  "$ASSETS/jb_updater_32x32.png" "$ASSETS/jb_updater_16x16.png" \
  "$ASSETS/jb_updater.ico" 2>/dev/null

echo "Icons in $ASSETS:"
ls -lh "$ASSETS"/jb_updater*
