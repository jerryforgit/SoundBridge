#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="driver/build/SoundBridge.driver"
DEST="/Library/Audio/Plug-Ins/HAL/SoundBridge.driver"

if [[ ! -d "$SRC" ]]; then
    echo "Build the driver first: ./driver/build.sh" >&2
    exit 1
fi

codesign --verify --deep --strict "$SRC"

echo "About to install SoundBridge HAL plugin:"
echo "  sudo rm -rf \"$DEST\""
echo "  sudo cp -R \"$SRC\" \"$DEST\""
echo "  sudo chown -R root:wheel \"$DEST\""
echo "  sudo chmod -R 755 \"$DEST\""
echo "  sudo killall coreaudiod    # audio stops for 2-3 seconds"
echo
echo "SpeakerAmp is NOT touched. Default output is NOT changed."
echo
read "answer?Continue? [y/N] "
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo rm -rf "$DEST"
sudo cp -R "$SRC" "$DEST"
sudo chown -R root:wheel "$DEST"
sudo chmod -R 755 "$DEST"

echo "Restarting coreaudiod; audio will be interrupted for 2-3 seconds..."
sudo killall coreaudiod || true
sleep 3

echo
echo "Installed: $DEST"
echo "Check devices with:"
echo "  ./tools/audiodefault list"
echo
echo "If something goes wrong, uninstall with:"
echo "  ./scripts/uninstall.sh"
