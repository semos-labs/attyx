#!/bin/bash
# Test the custom updater locally.
#
# Uses "AttyxDev.app" with a separate bundle ID so it won't interfere
# with a production Attyx install.
#
# What this does:
#   1. Builds the app as "v1" (version 0.0.1)
#   2. Packages it into AttyxDev.app
#   3. Builds a "v2" (version 0.0.2) and packages it as a zip
#   4. Creates a local appcast feed pointing to v2
#   5. Starts a local HTTP server
#   6. Installs v1 to ~/Applications and launches it with ATTYX_FEED_URL
#
# After launch, click "Check for Updates" in the menu (or wait 5s)
# and verify the update window appears, downloads, and installs v2.
#
# Usage:
#   ./scripts/test-update.sh

set -e
cd "$(dirname "$0")/.."

STAGING="/tmp/attyx-update-test"
INSTALL_DIR="$HOME/Applications"
APP_NAME="AttyxDev"
BUNDLE_ID="com.semos-labs.attyx.dev"

rm -rf "$STAGING"
mkdir -p "$STAGING"/{v1,v2,serve}
mkdir -p "$INSTALL_DIR"

# Create a test Info.plist with dev bundle ID
make_plist() {
    local VERSION="$1"
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>attyx</string>
    <key>CFBundleIconFile</key>
    <string>Attyx</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>http://localhost:8089/appcast.xml</string>
</dict>
</plist>
PLIST
}

echo "=== Building binary ==="
zig build 2>&1

# --- v1 ---
echo "=== Packaging v1 (0.0.1) ==="
APP="$STAGING/v1/${APP_NAME}.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp zig-out/bin/attyx "$APP/Contents/MacOS/attyx"
make_plist "0.0.1" > "$APP/Contents/Info.plist"
if [ -f images/Attyx.png ]; then
    ICONSET=$(mktemp -d)/Attyx.iconset
    mkdir -p "$ICONSET"
    sips -z 128 128 images/Attyx.png --out "$ICONSET/icon_128x128.png" 2>/dev/null
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Attyx.icns" 2>/dev/null || true
    rm -rf "$(dirname "$ICONSET")"
fi
codesign --force --sign - "$APP"
echo "  v1 ready: $APP"

# --- v2 ---
echo "=== Packaging v2 (0.0.2) ==="
APP2="$STAGING/v2/${APP_NAME}.app"
mkdir -p "$APP2/Contents/MacOS"
mkdir -p "$APP2/Contents/Resources"
cp zig-out/bin/attyx "$APP2/Contents/MacOS/attyx"
make_plist "0.0.2" > "$APP2/Contents/Info.plist"
codesign --force --sign - "$APP2"

cd "$STAGING/v2"
ditto -c -k --keepParent "${APP_NAME}.app" "$STAGING/serve/attyx-update.zip"
cd - > /dev/null
echo "  v2 zipped"

# --- Appcast ---
echo "=== Creating appcast feed ==="
V2_SIZE=$(stat -f%z "$STAGING/serve/attyx-update.zip")
PUB_DATE=$(date -u '+%a, %d %b %Y %H:%M:%S %z')

cat > "$STAGING/serve/appcast.xml" <<FEED
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${APP_NAME} Test Feed</title>
    <item>
      <title>${APP_NAME} v0.0.2</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:releaseNotesLink>http://localhost:8089/release-notes.html</sparkle:releaseNotesLink>
      <enclosure
        url="http://localhost:8089/attyx-update.zip"
        sparkle:version="0.0.2"
        sparkle:shortVersionString="0.0.2"
        length="${V2_SIZE}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
FEED

cat > "$STAGING/serve/release-notes.html" <<'HTML'
<!DOCTYPE html>
<html>
<head><style>
  body { font-family: -apple-system, system-ui; font-size: 13px; padding: 12px; }
  h2 { font-size: 15px; margin-top: 0; }
  li { margin: 4px 0; }
</style></head>
<body>
  <h2>AttyxDev 0.0.2</h2>
  <ul>
    <li>Custom updater &#8212; no more App Management permission prompt</li>
    <li>This is a test release for local update testing</li>
  </ul>
</body>
</html>
HTML

# --- Launch ---
echo "=== Starting local HTTP server on port 8089 ==="
cd "$STAGING/serve"
python3 -m http.server 8089 &
SERVER_PID=$!
cd - > /dev/null
sleep 1

echo "=== Installing v1 to ~/Applications ==="
rm -rf "$INSTALL_DIR/${APP_NAME}.app"
cp -R "$STAGING/v1/${APP_NAME}.app" "$INSTALL_DIR/${APP_NAME}.app"
echo "  Installed: $INSTALL_DIR/${APP_NAME}.app (0.0.1)"

echo ""
echo "=== Launching ${APP_NAME} ==="
echo "  Feed: http://localhost:8089/appcast.xml"
echo ""
echo "  The app will auto-check for updates after 5 seconds."
echo "  You can also use the menu: ${APP_NAME} → Check for Updates."
echo ""
echo "  After the update installs, verify:"
echo "    1. No 'App Management' permission prompt appeared"
echo "    2. The app relaunched successfully"
echo "    3. About shows version 0.0.2"
echo ""
echo "  Press Ctrl+C when done to stop the test server."
echo ""

ATTYX_FEED_URL="http://localhost:8089/appcast.xml" open "$INSTALL_DIR/${APP_NAME}.app"

trap "kill $SERVER_PID 2>/dev/null; echo 'Server stopped.'" EXIT
wait $SERVER_PID 2>/dev/null || true
