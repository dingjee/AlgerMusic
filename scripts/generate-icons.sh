#!/bin/sh
# Export assets only; never build, install, or restart the application.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
mkdir -p "$ROOT/.artifacts"
STAGE="$(mktemp -d "$ROOT/.artifacts/icons.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

bun run tauri icon src-tauri/icons/app-icon-macos.svg --output "$STAGE/macos" --png 1024
bun run tauri icon src-tauri/icons/app-icon-ios.svg --output "$STAGE/ios" --png 1024
swift scripts/export-icons.swift "$STAGE" src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset/Contents.json
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$STAGE/desktop/icon.icns"
iconutil -c iconset "$STAGE/desktop/icon.icns" -o "$STAGE/verify.iconset"
swift scripts/export-icons.swift --verify-png \
  "$STAGE/AppIcon.iconset/icon_512x512@2x.png" "$STAGE/verify.iconset/icon_512x512@2x.png"

# Publish only after both platform exports and ICNS packaging have verified.
for name in 32x32.png 128x128.png 128x128@2x.png icon.png icon.icns icon-macos.png icon-ios.png; do
  cp "$STAGE/desktop/$name" "$ROOT/src-tauri/icons/$name"
done
for icon in "$STAGE/ios-assets/"*.png; do
  cp "$icon" "$ROOT/src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset/"
done
echo 'Generated macOS ICNS / PNG and 18 iOS AppIcon assets; application was not built or installed.'
