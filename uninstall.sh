#!/bin/bash
# Полностью удаляет LayoutGlow (и старую установку через LaunchAgent, если была).
set -uo pipefail

launchctl bootout "gui/$UID/ru.devkz.layoutglow" 2>/dev/null
pkill -x LayoutGlow 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/ru.devkz.layoutglow.plist"
rm -rf "$HOME/Library/Application Support/LayoutGlow"
rm -rf "/Applications/LayoutGlow.app" "$HOME/Applications/LayoutGlow.app"
echo "LayoutGlow удалён."
