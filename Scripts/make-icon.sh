#!/bin/bash
# Regenerates Resources/AppIcon.icns from Scripts/make-icon.swift.
source "$(dirname "$0")/common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
swift "$ROOT/Scripts/make-icon.swift" "$WORK/icon.png"
SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$WORK/icon.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p "$ROOT/Resources"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
cp "$WORK/icon.png" "$ROOT/Resources/AppIcon.png"
echo "Wrote Resources/AppIcon.icns"
