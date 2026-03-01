#!/bin/bash
set -e

cd "$(dirname "$0")/.."

# Build release binary
echo "Building release..."
zig build

APP="Attyx.app"
rm -rf "$APP"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"

# Binary
cp zig-out/bin/attyx "$APP/Contents/MacOS/attyx"

# Info.plist
cp resources/Info.plist "$APP/Contents/"

# App icon (generate .icns from PNG if sips is available)
if [ -f images/Attyx.png ]; then
  ICONSET=$(mktemp -d)/Attyx.iconset
  mkdir -p "$ICONSET"
  sips -z 16 16 images/Attyx.png --out "$ICONSET/icon_16x16.png" 2>/dev/null
  sips -z 32 32 images/Attyx.png --out "$ICONSET/icon_16x16@2x.png" 2>/dev/null
  sips -z 32 32 images/Attyx.png --out "$ICONSET/icon_32x32.png" 2>/dev/null
  sips -z 64 64 images/Attyx.png --out "$ICONSET/icon_32x32@2x.png" 2>/dev/null
  sips -z 128 128 images/Attyx.png --out "$ICONSET/icon_128x128.png" 2>/dev/null
  sips -z 256 256 images/Attyx.png --out "$ICONSET/icon_128x128@2x.png" 2>/dev/null
  sips -z 256 256 images/Attyx.png --out "$ICONSET/icon_256x256.png" 2>/dev/null
  sips -z 512 512 images/Attyx.png --out "$ICONSET/icon_256x256@2x.png" 2>/dev/null
  sips -z 512 512 images/Attyx.png --out "$ICONSET/icon_512x512.png" 2>/dev/null
  sips -z 1024 1024 images/Attyx.png --out "$ICONSET/icon_512x512@2x.png" 2>/dev/null
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Attyx.icns"
  rm -rf "$(dirname "$ICONSET")"
  echo "Icon: OK"
fi

# Bundle Sparkle.framework
if [ -d vendor/Sparkle.framework ]; then
  cp -a vendor/Sparkle.framework "$APP/Contents/Frameworks/"
  echo "Sparkle: OK"
fi

# Ad-hoc sign (no Apple Developer account needed)
codesign --force --deep --sign - "$APP"

echo ""
echo "Done: $APP"
echo "Run with: open $APP"
