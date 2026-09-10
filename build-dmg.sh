#!/bin/bash
# Собирает LayoutGlow.app и упаковывает в LayoutGlow.dmg для переноса на другие маки.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/LayoutGlow.app"
DMG="$DIR/LayoutGlow.dmg"

rm -rf "$BUILD" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Компилирую..."
swiftc -O -framework Cocoa -framework Carbon "$DIR/Core.swift" "$DIR/Smoke.swift" "$DIR/Clipboard.swift" "$DIR/Preferences.swift" "$DIR/main.swift" -o "$APP/Contents/MacOS/LayoutGlow"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>ru.devkz.layoutglow</string>
    <key>CFBundleName</key><string>LayoutGlow</string>
    <key>CFBundleExecutable</key><string>LayoutGlow</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>5.7</string>
    <key>CFBundleVersion</key><string>36</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Константин Жебенев. Лицензия MIT.</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Иконка: пересобирается, если исходник новее готового .icns
if [ ! -f "$DIR/icon/AppIcon.icns" ] || [ "$DIR/icon/make-icon.swift" -nt "$DIR/icon/AppIcon.icns" ]; then
    (cd "$DIR" && swift icon/make-icon.swift >/dev/null && iconutil -c icns icon/AppIcon.iconset -o icon/AppIcon.icns)
fi
cp "$DIR/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$DIR/LICENSE" "$APP/Contents/Resources/LICENSE"

# Подпись постоянным самоподписанным сертификатом: без неё каждая пересборка
# меняет хеш бинарника и macOS сбрасывает выданные разрешения.
KEYCHAIN="$HOME/Library/Keychains/layoutglow.keychain-db"
CN="LayoutGlow Self-Signed"
if [ ! -f "$KEYCHAIN" ] && [ -x "$DIR/setup-signing.sh" ]; then
    "$DIR/setup-signing.sh"
fi
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CN"; then
    PASSFILE="$HOME/Library/Application Support/LayoutGlow/signing.pass"
    PASS=""
    [ -f "$PASSFILE" ] && PASS="$(cat "$PASSFILE")"
    [ -z "$PASS" ] && PASS="$(security find-generic-password -s ru.devkz.layoutglow.signing -w 2>/dev/null || true)"
    if [ -z "$PASS" ] || ! security unlock-keychain -p "$PASS" "$KEYCHAIN" 2>/dev/null; then
        echo "Пароль подписи потерян — пересоздаю сертификат."
        "$DIR/setup-signing.sh"
        PASS="$(cat "$PASSFILE" 2>/dev/null)"
        security unlock-keychain -p "$PASS" "$KEYCHAIN" 2>/dev/null || true
    fi
    codesign --force --keychain "$KEYCHAIN" -s "$CN" "$APP"
else
    echo "Внимание: подписываю ad-hoc — разрешения придётся выдавать заново после каждой пересборки."
    codesign --force -s - "$APP"
fi

echo "Собираю DMG..."
STAGE="$BUILD/dmg-root"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname LayoutGlow -srcfolder "$STAGE" -format UDZO -quiet "$DMG"

echo "Готово: $DMG"
