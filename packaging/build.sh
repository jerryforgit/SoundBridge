#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
OUT="$ROOT/packaging/build"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "== Build driver =="
"$ROOT/driver/build.sh"

echo "== Build app =="
"$ROOT/app/build.sh"

echo "== Stage install payload =="
INSTALL_ROOT="$OUT/install-root"
mkdir -p "$INSTALL_ROOT/Applications"
mkdir -p "$INSTALL_ROOT/Library/Audio/Plug-Ins/HAL"
cp -R "$ROOT/app/build/SoundBridge.app" "$INSTALL_ROOT/Applications/"
cp -R "$ROOT/driver/build/SoundBridge.driver" \
      "$INSTALL_ROOT/Library/Audio/Plug-Ins/HAL/"

chmod +x "$ROOT/packaging/install-scripts/postinstall"
chmod +x "$ROOT/packaging/uninstall-scripts/postinstall"

echo "== Build SoundBridge.pkg =="
pkgbuild \
    --root "$INSTALL_ROOT" \
    --identifier "com.jerry.soundbridge.pkg" \
    --version "0.1" \
    --scripts "$ROOT/packaging/install-scripts" \
    --install-location "/" \
    "$OUT/SoundBridge.pkg"

echo "== Stage uninstall payload =="
UNINSTALL_ROOT="$OUT/uninstall-root"
mkdir -p "$UNINSTALL_ROOT/private/tmp"
: > "$UNINSTALL_ROOT/private/tmp/.soundbridge-uninstall-marker"

echo "== Build Uninstall SoundBridge.pkg =="
pkgbuild \
    --root "$UNINSTALL_ROOT" \
    --identifier "com.jerry.soundbridge.uninstall.pkg" \
    --version "0.1" \
    --scripts "$ROOT/packaging/uninstall-scripts" \
    --install-location "/" \
    "$OUT/Uninstall SoundBridge.pkg"

echo
ls -lh "$OUT/SoundBridge.pkg" "$OUT/Uninstall SoundBridge.pkg"
echo
echo "Install:"
echo "  sudo installer -pkg \"$OUT/SoundBridge.pkg\" -target /"
echo "Uninstall:"
echo "  sudo installer -pkg \"$OUT/Uninstall SoundBridge.pkg\" -target /"
