#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
BUILD=build
PLUGIN_NAME=SoundBridge
DRIVER="$BUILD/$PLUGIN_NAME.driver"
ASPL=third_party/libASPL
MIN_MACOS=13.0
ARCHS=(arm64 x86_64)

rm -rf "$BUILD/libaspl"
mkdir -p "$BUILD/libaspl"

compile_libaspl() {
    local arch="$1"
    local out="$BUILD/libaspl/$arch"
    mkdir -p "$out"
    local src="$ASPL/src"
    local files=(
        "$src/Device.cpp" "$src/Device.g.cpp"
        "$src/MuteControl.cpp" "$src/MuteControl.g.cpp"
        "$src/Object.cpp" "$src/Object.g.cpp"
        "$src/Plugin.cpp" "$src/Plugin.g.cpp"
        "$src/Stream.cpp" "$src/Stream.g.cpp"
        "$src/VolumeControl.cpp" "$src/VolumeControl.g.cpp"
        "$src/Bridge.g.cpp" "$src/Strings.g.cpp"
        "$src/Client.cpp" "$src/Convert.cpp" "$src/Dispatcher.cpp"
        "$src/Driver.cpp" "$src/Storage.cpp" "$src/Strings.cpp"
        "$src/Tracer.cpp" "$src/Uid.cpp" "$src/VolumeCurve.cpp"
    )
    local objects=()
    for file in "${files[@]}"; do
        local obj="$out/$(basename "$file" .cpp).o"
        xcrun clang++ -std=c++17 -O2 -fPIC \
            -arch "$arch" -mmacosx-version-min="$MIN_MACOS" -isysroot "$SDK" \
            -I "$ASPL/include" \
            -I "$SDK/System/Library/Frameworks/CoreAudio.framework/Headers" \
            -Wno-invalid-offsetof -Wno-unused-parameter \
            -c "$file" -o "$obj"
        objects+=("$obj")
    done
    xcrun libtool -static -o "$out/libASPL.a" "${objects[@]}" >/dev/null
    echo "Built libASPL for $arch"
}

for arch in "${ARCHS[@]}"; do
    compile_libaspl "$arch"
done

echo "Building $PLUGIN_NAME.driver (universal)..."
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"

binaries=()
for arch in "${ARCHS[@]}"; do
    local_bin="$BUILD/$PLUGIN_NAME-$arch"
    xcrun clang++ -std=c++17 -O2 -fPIC \
        -arch "$arch" -mmacosx-version-min="$MIN_MACOS" -isysroot "$SDK" \
        -I "$ASPL/include" \
        -I "$SDK/System/Library/Frameworks/CoreAudio.framework/Headers" \
        -bundle \
        -o "$local_bin" \
        SoundBridge/SoundBridge.cpp "$BUILD/libaspl/$arch/libASPL.a" \
        -framework CoreFoundation -framework CoreAudio
    binaries+=("$local_bin")
done

xcrun lipo -create "${binaries[@]}" -output "$DRIVER/Contents/MacOS/$PLUGIN_NAME"
rm -f "${binaries[@]}"

cp SoundBridge/Info.plist "$DRIVER/Contents/Info.plist"

# 自用 ad-hoc 签名；Apple Silicon 上 coreaudiod 会校验签名。
codesign --force --deep --sign - "$DRIVER"
codesign --verify --deep --strict "$DRIVER"

plutil -lint "$DRIVER/Contents/Info.plist" >/dev/null

echo "Built: $(pwd)/$DRIVER"
lipo -archs "$DRIVER/Contents/MacOS/$PLUGIN_NAME"
codesign -dv --verbose=2 "$DRIVER" 2>&1 | grep -E "Identifier|Format|CDHash|Signature"
