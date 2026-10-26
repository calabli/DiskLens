#!/bin/sh
# Renders Assets/AppIcon.svg into Assets/AppIcon.icns (needs rsvg-convert: brew install librsvg).
set -e
cd "$(dirname "$0")/.."
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size Assets/AppIcon.svg -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) Assets/AppIcon.svg -o "$SET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$SET" -o Assets/AppIcon.icns
echo "wrote Assets/AppIcon.icns"
