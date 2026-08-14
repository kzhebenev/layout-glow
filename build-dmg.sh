#!/bin/bash
# Собирает LayoutGlow.app и упаковывает в LayoutGlow.dmg для переноса на другие маки.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/LayoutGlow.app"
DMG="$DIR/LayoutGlow.dmg"

rm -rf "$BUILD" "$DMG"
mkdir -p "$APP/Contents/MacOS"

echo "Компилирую..."
swiftc -O -framework Cocoa -framework Carbon "$DIR/main.swift" -o "$APP/Contents/MacOS/LayoutGlow"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ru.devkz.layoutglow</string>
    <key>CFBundleName</key><string>LayoutGlow</string>
    <key>CFBundleExecutable</key><string>LayoutGlow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force -s - "$APP"

echo "Собираю DMG..."
STAGE="$BUILD/dmg-root"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname LayoutGlow -srcfolder "$STAGE" -format UDZO -quiet "$DMG"

echo "Готово: $DMG"
