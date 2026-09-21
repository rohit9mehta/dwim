#!/bin/bash
# Builds DWIM.app next to this script. No Xcode project or developer account needed.
set -e
cd "$(dirname "$0")"
APP=DWIM.app
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.rohitm.dwim</string>
  <key>CFBundleName</key><string>DWIM</string>
  <key>CFBundleExecutable</key><string>DWIM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/DWIM"
# A stable signing identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it every time.
if security find-identity -v -p codesigning | grep -q "DWIM Dev"; then ID="DWIM Dev"; else ID="-"; fi
codesign --force --sign "$ID" "$APP"
echo "signed with: $ID"
echo "built $PWD/$APP"
