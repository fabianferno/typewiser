#!/usr/bin/env bash
# Renders Resources/AppIcon.png (1024x1024 master) into Resources/AppIcon.icns.
# Run this only when the logo changes; the .icns is committed, so a normal
# build (Scripts/bundle-app.sh) does not need it.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Resources/AppIcon.png"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
