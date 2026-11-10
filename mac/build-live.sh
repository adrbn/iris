#!/bin/sh
# Builds IrisLive.app, signed with the Developer ID so the Bluetooth permission survives rebuilds.
set -e
cd "$(dirname "$0")/.."
APP=mac/IrisLive.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/IrisLive" Iris/Protocol.swift mac/main.swift 
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.adrbn.iris.live</string>
<key>CFBundleName</key><string>Iris Live</string>
<key>CFBundleExecutable</key><string>IrisLive</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Iris Live récupère les images de tes lunettes pour les montrer à distance.</string>
</dict></plist>
PL
# A stable Developer ID keeps the Accessibility and Bluetooth grants across rebuilds; ad hoc otherwise.
IDENTITY="${IRIS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "ok $APP"
