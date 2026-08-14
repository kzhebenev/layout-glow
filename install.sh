#!/bin/bash
# Собирает LayoutGlow.app, ставит в /Applications и запускает.
# Автозапуск приложение включает себе само (Login Item) при первом запуске.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

# Убираем старую установку через LaunchAgent, если была
launchctl bootout "gui/$UID/ru.devkz.layoutglow" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/ru.devkz.layoutglow.plist"
rm -rf "$HOME/Library/Application Support/LayoutGlow"
pkill -x LayoutGlow 2>/dev/null || true
sleep 0.3

"$DIR/build-dmg.sh"

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/LayoutGlow.app"
cp -R "$DIR/build/LayoutGlow.app" "$DEST/"
open "$DEST/LayoutGlow.app"
echo "Готово: LayoutGlow установлен в $DEST и запущен, автозапуск включён."
