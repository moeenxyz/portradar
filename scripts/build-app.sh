#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/PortRadar.app"
BIN_PATH="$ROOT_DIR/.build/release/PortRadar"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ICONSET_DIR="$ROOT_DIR/.build/PortRadar.iconset"
ICON_PATH="$ROOT_DIR/icon.svg"

if [[ ! -f "$ICON_PATH" && -f "$APP_DIR/Contents/MacOS/icon.svg" ]]; then
  ICON_PATH="$APP_DIR/Contents/MacOS/icon.svg"
fi

swift build -c release --package-path "$ROOT_DIR"

mkdir -p "$APP_DIR/Contents/MacOS" "$RESOURCES_DIR"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/PortRadar"

if [[ -f "$ICON_PATH" ]]; then
  rm -rf "$ICONSET_DIR"
  swift "$ROOT_DIR/scripts/make-icon.swift" "$ICON_PATH" "$ICONSET_DIR"
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PortRadar</string>
    <key>CFBundleDisplayName</key>
    <string>PortRadar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.portradar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PortRadar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "Built $APP_DIR"
