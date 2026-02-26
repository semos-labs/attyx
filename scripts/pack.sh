#!/bin/bash
set -e

APP="Attyx.app"
rm -rf "$APP"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp resources/Info.plist "$APP/Contents/"
cp zig-out/bin/attyx "$APP/Contents/MacOS/attyx"

# Ad-hoc sign (no Apple Developer account needed, just removes the quarantine issue)
codesign --force --deep --sign - "$APP"

echo "Done: $APP"
