#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

DEST="/Library/Audio/Plug-Ins/HAL/SoundBridge.driver"
CURRENT_DEFAULT=$(./tools/audiodefault get 2>/dev/null | awk -F': *' '/default output:/{print $2}' || true)

echo "About to remove SoundBridge HAL plugin:"
echo "  sudo rm -rf \"$DEST\""
echo "  sudo killall coreaudiod    # audio stops for 2-3 seconds"
echo
if [[ -n "${CURRENT_DEFAULT}" ]]; then
    echo "Current default output: $CURRENT_DEFAULT"
    echo "If it is SoundBridge, switch it back to SpeakerAmp or the display BEFORE removing."
    echo
fi
read "answer?Continue? [y/N] "
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

sudo rm -rf "$DEST"
echo "Restarting coreaudiod..."
sudo killall coreaudiod || true
sleep 3

echo "Removed: $DEST"
echo "SpeakerAmp / BlackHole / MAXHUB drivers were not touched."
