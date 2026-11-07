#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP=build/SoundBridge.app
BIN="$APP/Contents/MacOS/SoundBridge"
MIN_MACOS=13.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ ! -f build/AppIcon.icns ]]; then
    ./make_icon.sh
fi

SOURCES=(
    ../engine/Engine.swift
    ../engine/DSP.swift
    ../engine/EQ.swift
    ../engine/SharedRing.swift
    ../engine/MatrixReverbAU.swift
    AudioControl.swift
    AppDelegate.swift
    SpatialWindowController.swift
    EQWindowController.swift
    ControlPanelWindowController.swift
    Localization.swift
    Shortcuts.swift
    ShortcutsWindowController.swift
    LoginItem.swift
    main.swift
)

FRAMEWORKS=(
    -framework AppKit
    -framework CoreAudio
    -framework AudioToolbox
    -framework ServiceManagement
    -framework Carbon
)

for arch in arm64 x86_64; do
    echo "Compiling $arch..."
    xcrun swiftc -O \
        -target "${arch}-apple-macos${MIN_MACOS}" \
        "${FRAMEWORKS[@]}" \
        -o "build/SoundBridge-${arch}" \
        "${SOURCES[@]}"
done

echo "Creating universal binary..."
xcrun lipo -create \
    build/SoundBridge-arm64 \
    build/SoundBridge-x86_64 \
    -output "$BIN"
rm -f build/SoundBridge-arm64 build/SoundBridge-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "Built: $(pwd)/$APP"
lipo -archs "$BIN"
