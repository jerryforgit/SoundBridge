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

# Remove Finder/Syncthing junk so it does not end up in the package payload.
find "$INSTALL_ROOT" \( -name '._*' -o -name '.DS_Store' \) -delete
# Strip extended attributes so the cpio payload does not contain AppleDouble
# (._*) sidecar entries.
xattr -cr "$INSTALL_ROOT" 2>/dev/null || true

chmod +x "$ROOT/packaging/install-scripts/preinstall" \
         "$ROOT/packaging/install-scripts/postinstall" \
         "$ROOT/packaging/uninstall-scripts/postinstall"

echo "== Disable bundle relocation =="
# Installer otherwise "relocates" SoundBridge.app to any copy it finds on
# disk (including this build directory), which makes the absolute paths in
# postinstall fail. Force both bundles to install at their declared paths.
COMPONENT_PLIST="$OUT/component.plist"
pkgbuild --analyze --root "$INSTALL_ROOT" "$COMPONENT_PLIST"
for i in 0 1 2 3 4 5; do
    bundle_path=$(/usr/libexec/PlistBuddy -c "Print :$i:RootRelativeBundlePath" "$COMPONENT_PLIST" 2>/dev/null || true)
    if [ "$bundle_path" = "Applications/SoundBridge.app" ]; then
        /usr/libexec/PlistBuddy -c "Delete :$i:BundleIsRelocatable" "$COMPONENT_PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" "$COMPONENT_PLIST"
        /usr/libexec/PlistBuddy -c "Add :$i:BundleHasStrictIdentifier bool true" "$COMPONENT_PLIST" 2>/dev/null || true
    fi
    if [ "$bundle_path" = "Library/Audio/Plug-Ins/HAL/SoundBridge.driver" ]; then
        /usr/libexec/PlistBuddy -c "Delete :$i:BundleIsRelocatable" "$COMPONENT_PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" "$COMPONENT_PLIST"
    fi
done
echo "--- component.plist ---"
/usr/libexec/PlistBuddy -c "Print" "$COMPONENT_PLIST"

echo "== Build SoundBridge.pkg =="
pkgbuild \
    --root "$INSTALL_ROOT" \
    --component-plist "$COMPONENT_PLIST" \
    --identifier "com.jerry.soundbridge.pkg" \
    --version "0.4" \
    --scripts "$ROOT/packaging/install-scripts" \
    --install-location "/" \
    "$OUT/SoundBridge.pkg"

echo "== Stage uninstall payload =="
UNINSTALL_ROOT="$OUT/uninstall-root"
mkdir -p "$UNINSTALL_ROOT/private/tmp"
: > "$UNINSTALL_ROOT/private/tmp/.soundbridge-uninstall-marker"

echo "== Build Uninstall.SoundBridge.pkg =="
pkgbuild \
    --root "$UNINSTALL_ROOT" \
    --identifier "com.jerry.soundbridge.uninstall.pkg" \
    --version "0.4" \
    --scripts "$ROOT/packaging/uninstall-scripts" \
    --install-location "/" \
    "$OUT/Uninstall.SoundBridge.pkg"

# Staging roots are not needed after packaging. Leaving them around also
# gives Installer another candidate path for bundle relocation.
rm -rf "$INSTALL_ROOT" "$UNINSTALL_ROOT" "$COMPONENT_PLIST"

echo
ls -lh "$OUT/SoundBridge.pkg" "$OUT/Uninstall.SoundBridge.pkg"
echo
shasum -a 256 "$OUT/SoundBridge.pkg" "$OUT/Uninstall.SoundBridge.pkg"
echo
echo "Install:"
echo "  sudo installer -pkg \"$OUT/SoundBridge.pkg\" -target /"
echo "Uninstall:"
echo "  sudo installer -pkg \"$OUT/Uninstall.SoundBridge.pkg\" -target /"
