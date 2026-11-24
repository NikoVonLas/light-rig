#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
MACOS_DIR="$PROJECT_DIR/macos"
BUILD_ROOT="$MACOS_DIR/.build/app"
APP="$BUILD_ROOT/Light Rig.app"
BUILD_CACHE="$MACOS_DIR/.build/caches"
export CLANG_MODULE_CACHE_PATH="$BUILD_CACHE/clang"

swift_release() {
    swift build -c release --disable-sandbox --scratch-path "$MACOS_DIR/.build/swift-release" \
        --cache-path "$BUILD_CACHE/swift" --config-path "$BUILD_CACHE/config" \
        --security-path "$BUILD_CACHE/security" \
        -Xswiftc -module-cache-path -Xswiftc "$BUILD_CACHE/modules" "$@"
}

cd "$MACOS_DIR"
swift_release
BIN_DIR=$(swift_release --show-bin-path)

"$SCRIPT_DIR/build_firmware.sh"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$MACOS_DIR/Support/LightRig.icns" "$APP/Contents/Resources/"
cp "$PROJECT_DIR/firmware/build/light_rig.bin" "$APP/Contents/Resources/Light-Rig-esp32s2.bin"
cp "$BIN_DIR/LightRig" "$APP/Contents/MacOS/LightRig"
cp "$MACOS_DIR/Support/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "$APP"
