#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
BUILD=build
LIBDIR="$BUILD/libaspl"
LIB="$LIBDIR/libASPL.a"
PLUGIN_NAME=SoundBridge
DRIVER="$BUILD/$PLUGIN_NAME.driver"
ASPL=third_party/libASPL

mkdir -p "$LIBDIR"

compile_libaspl() {
    echo "Compiling libASPL..."
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
        local obj="$LIBDIR/$(basename "$file" .cpp).o"
        xcrun clang++ -std=c++17 -O2 -fPIC -arch arm64 -isysroot "$SDK" \
            -I "$ASPL/include" \
            -I "$SDK/System/Library/Frameworks/CoreAudio.framework/Headers" \
            -Wno-invalid-offsetof -Wno-unused-parameter \
            -c "$file" -o "$obj"
        objects+=("$obj")
    done
    xcrun libtool -static -o "$LIB" "${objects[@]}" >/dev/null
    echo "Built $LIB"
}

if [[ ! -f "$LIB" ]]; then
    compile_libaspl
fi

echo "Building $PLUGIN_NAME.driver..."
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"

xcrun clang++ -std=c++17 -O2 -fPIC -arch arm64 -isysroot "$SDK" \
    -I "$ASPL/include" \
    -I "$SDK/System/Library/Frameworks/CoreAudio.framework/Headers" \
    -bundle \
    -o "$DRIVER/Contents/MacOS/$PLUGIN_NAME" \
    SoundBridge/SoundBridge.cpp "$LIB" \
    -framework CoreFoundation -framework CoreAudio

cp SoundBridge/Info.plist "$DRIVER/Contents/Info.plist"

# 自用 ad-hoc 签名；Apple Silicon 上 coreaudiod 会校验签名。
codesign --force --deep --sign - "$DRIVER"
codesign --verify --deep --strict "$DRIVER"

plutil -lint "$DRIVER/Contents/Info.plist" >/dev/null

echo "Built: $(pwd)/$DRIVER"
codesign -dv --verbose=2 "$DRIVER" 2>&1 | grep -E "Identifier|Format|CDHash|Signature"
