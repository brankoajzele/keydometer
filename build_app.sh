#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="build"
APP_NAME="Keydometer.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICON_SOURCE="keydometer.png"
ICONSET_DIR="$BUILD_DIR/Icon.iconset"
ICON_DEST="$RESOURCES_DIR/Keydometer.icns"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp Info.plist "$CONTENTS_DIR/Info.plist"

BIN_PATH="$BUILD_DIR/Keydometer"

swiftc src/*.swift \
  -o "$BIN_PATH" \
  -framework Cocoa \
  -framework ApplicationServices

cp "$BIN_PATH" "$MACOS_DIR/Keydometer"

if [ -f "$ICON_SOURCE" ]; then
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  generate_icon() {
    local size="$1"
    local name="$2"
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/$name" >/dev/null
  }

  generate_icon 16 "icon_16x16.png"
  generate_icon 32 "icon_16x16@2x.png"
  generate_icon 32 "icon_32x32.png"
  generate_icon 64 "icon_32x32@2x.png"
  generate_icon 128 "icon_128x128.png"
  generate_icon 256 "icon_128x128@2x.png"
  generate_icon 256 "icon_256x256.png"
  generate_icon 512 "icon_256x256@2x.png"
  generate_icon 512 "icon_512x512.png"
  generate_icon 1024 "icon_512x512@2x.png"

  iconutil -c icns "$ICONSET_DIR" -o "$ICON_DEST"
  rm -rf "$ICONSET_DIR"
else
  echo "Warning: $ICON_SOURCE not found – using default app icon."
fi

echo "Built $APP_DIR – double-click it in Finder to run Keydometer in the background."
