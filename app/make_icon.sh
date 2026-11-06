#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build/AppIcon.iconset build/AppIcon.png build/AppIcon.icns
mkdir -p build/AppIcon.iconset

xcrun swift make_icon.swift build/AppIcon.png

for size in 16 32 64 128 256 512; do
    sips -z $size $size build/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double build/AppIcon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done

cp build/AppIcon.png build/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

echo "Built: $(pwd)/build/AppIcon.icns"
