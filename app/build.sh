#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP=build/SoundBridge.app
BIN="$APP/Contents/MacOS/SoundBridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ ! -f build/AppIcon.icns ]]; then
    ./make_icon.sh
fi

xcrun swiftc -O \
    -framework AppKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework ServiceManagement \
    -o "$BIN" \
    ../engine/Engine.swift \
    ../engine/DSP.swift \
    ../engine/EQ.swift \
    ../engine/SharedRing.swift \
    ../engine/MatrixReverbAU.swift \
    AudioControl.swift \
    AppDelegate.swift \
    SpatialWindowController.swift \
    EQWindowController.swift \
    ControlPanelWindowController.swift \
    Localization.swift \
    LoginItem.swift \
    main.swift

cp Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "Built: $(pwd)/$APP"
